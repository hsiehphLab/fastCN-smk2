import pandas as pd
import numpy as np
import math
import os
import sys


def find_reads(wc):
    if config["reads"][wc.sm].endswith("fofn"):
        with open(config["reads"][wc.sm], "r") as infile:
            read_list = [x.rstrip() for x in infile]
        return read_list
    else:
        return config["reads"][wc.sm]


rule split_reads:
    input:
        reads=find_reads,
    output:
        reads=temp(scatter.split("temp/reads/{{sm}}/{scatteritem}.fq.gz")),
    conda:
        "fastcn3_env"
    resources:
        mem_mb=1024 * 2,
        runtime=60 * 8,
        load=100,  # seeting a high load here so that only a few can run at once
    params:
        unzipped=scatter.split("temp/reads/{{sm}}/{scatteritem}.fq"),
    log:
        "logs/split_reads/{sm}.log",
    benchmark:
        "benchmarks/split_reads/{sm}.tbl"
    threads: 8
    priority: 10
    shell:
        """
        if [[ $( echo {input.reads} ) =~ \.(fasta|fasta.gz|fa|fa.gz|fastq|fastq.gz|fq|fq.gz)$ ]]; then 
            #cat {input.reads} \ DG 2025.06.18 since gave error "rustybam: command not found"
            module load rustybam/0.1.31 && cat {input.reads} \
                | seqtk seq -F '#' \
                | rustybam fastq-split {output.reads} 
        elif [[ $( echo {input.reads} ) =~ \.(bam|cram|sam|sam.gz)$ ]]; then 
            #samtools fasta -@ {threads} {input.reads} \ DG 2025.06.18 since gave error "rustybam: command not found"
            module load rustybam/0.1.31 && samtools fasta -@ {threads} {input.reads} \
                | seqtk seq -F '#' \
                | rustybam fastq-split {output.reads} 
        fi 
        """


rule mrsfast_index:
    input:
        ref=config.get("masked_ref", rules.masked_reference.output.fasta),
    output:
        index=config.get("masked_ref", rules.masked_reference.output.fasta) + ".index",
    conda:
        "fastcn3_env"
    log:
        "logs/mrsfast/index.{sample}.log",
    resources:
        mem_mb=1024 * 8,
        runtime=60 * 24,
    threads: 1
    shell:
        """
        mrsfast --index {input.ref}
        """


rule mrsfast_alignment:
    input:
        reads="temp/reads/{sm}/{scatteritem}.fq.gz",
        index=rules.mrsfast_index.output.index,
        ref=config.get("masked_ref", rules.masked_reference.output.fasta),
    output:
        sam=temp("temp/mrsfast/{sample}/{sm}/mrsfast.{scatteritem}.sam.gz"),
    conda:
        "fastcn3_env"
    resources:
        total_mem=lambda wildcards, attempt, threads: 8 * attempt * threads - 2,
        mem_mb=lambda wildcards, attempt, threads: 1024 * 8 * attempt * threads,
        runtime=60 * 4,
        load=1,
    benchmark:
        "benchmarks/{sample}/mrsfast/{sm}/{scatteritem}.tbl"
    threads: 4
    priority: 20
    shell:
        """
        mkdir -p $(dirname {output.sam})

        # mrsfast here gave seg faults June 29, 2025 and also on May 8, 2025 both with this
        # conda environment and even with the one from run2.
        # extract-from-fastq36.py --in {input.reads} \
        #     | mrsfast --search {input.ref} --seq /dev/stdin \
        #         --disable-nohits --mem {resources.total_mem} --threads {threads} \
        #         -e 2 --outcomp \
        #         -o $(dirname {output.sam})/mrsfast.{wildcards.scatteritem}
        export PATH=/projects/standard/hsiehph/shared/software/packages/mrsfast/sfu-compbio-mrsfast-cf8e678:$PATH && extract-from-fastq36.py --in {input.reads} \
            | mrsfast --search {input.ref} --seq /dev/stdin \
                --disable-nohits --mem {resources.total_mem} --threads {threads} \
                -e 2 --outcomp \
                -o $(dirname {output.sam})/mrsfast.{wildcards.scatteritem}
        """


rule mrsfast_sort:
    input:
        sam=rules.mrsfast_alignment.output.sam,
    output:
        bam=temp("temp/mrsfast/{sample}/{sm}/{scatteritem}.bam"),
    conda:
        "fastcn3_env"
    log:
        "logs/{sample}/mrsfast/sort/{sm}/{scatteritem}_sort.log",
    benchmark:
        "benchmarks/{sample}/sort_bam/{sm}/{scatteritem}.tbl"
    resources:
        #mem_mb=1024 * 4, failed 2025.06.23
        mem_mb=1024 * 8,
        runtime=60 * 24,
        load=1,
    threads: 2
    priority: 30
    shell:
        """
        zcat {input.sam} \
            | samtools view -b - \
            | samtools sort -@ {threads} \
             -T {resources.tmpdir} -m 2G \
             -o {output.bam} -
        """


rule merged_mrsfast_bam:
    input:
        bams=gather.split("temp/mrsfast/{{sample}}/{{sm}}/{scatteritem}.bam"),
    output:
        merged=temp("results/{sample}/mapping/{sm}_merged.out.gz"),
    conda:
        "fastcn3_env"
    resources:
        mem_mb=1024 * 4,
        runtime=60 * 24,
    benchmark:
        "benchmarks/{sample}/merge_mrsfast/{sm}.tbl"
    log:
        "logs/mrsfast/{sample}/{sm}.merged.log",
    threads: 4
    priority: 40
    shell:
        """
        samtools merge -@ {threads} - {input.bams} -u \
            | samtools view -h - \
            | awk 'BEGIN {{OFS="\\t"}} {{print $1,$2,$3,$4,$5}}' \
            | pigz -p {threads} \
        > {output.merged}
        """


rule compress_mrsfast_further:
    input:
        sam=rules.merged_mrsfast_bam.output.merged,
    output:
        comp="results/{sample}/mapping/{sm}_merged_comp.out.gz",
    conda:
        "fastcn3_env"
    resources:
        mem_mb=1024 * 2,
        runtime=60 * 24,
        load=25,
    benchmark:
        "benchmarks/{sample}/comp_mrsfast/{sm}.tbl"
    log:
        "logs/mrsfast/{sample}/{sm}.merged_comp.log",
    script:
        "../scripts/compress_mrsfast.py"
