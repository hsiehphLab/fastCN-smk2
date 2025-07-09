 pixi run --manifest-path pixi.toml \
   snakemake \
   --configfile config_new/real-test.yaml \
   --profile profiles/slurm-executor \
   --notemp --nolock \
   -k \
   $@
