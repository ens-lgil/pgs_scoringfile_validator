# Configure --------------------------------------------------------------------

configfile: "config.yaml"
STUDIES, = glob_wildcards(config["ss_file_pattern"])

# --------------------------Snakemake rules ------------------------------------


rule all:
    input:
        expand("harmonised/{ss_file}.tsv", ss_file=STUDIES)


# Formatting for summary statistics database

rule sumstat_format:
    input:
        "toformat/{ss_file}.tsv"
    output:
        "formatted/{ss_file}.tsv"
    shell:
        "python formatting_tools/sumstats_formatting.py "
        "-f {input} "
        "-d formatted/"


# Retrieve VCF reference files 

rule get_vcf_files:
    output:
        "vcf_refs/homo_sapiens-chr{chromosome}.vcf.gz"
    params:
        location=config["remote_vcf_location"]
    shell:
        "wget -P vcf_refs/ {params.location}/homo_sapiens-chr{wildcards.chromosome}.vcf.gz"


rule get_tbi_files:
    output:
        "vcf_refs/homo_sapiens-chr{chromosome}.vcf.gz.tbi"
    params:
        location=config["remote_vcf_location"]
    shell:
        "wget -P vcf_refs/ {params.location}/homo_sapiens-chr{wildcards.chromosome}.vcf.gz.tbi"


# Split files into fractions for parallelisation of mapping and liftover (e.g. split into 16 and then again by 16)

rule split_file:
    input:
        "formatted/{ss_file}.tsv"
    output:
        expand("formatted/{{ss_file}}/bpsplit_{step}_bpsplit_{split}_{{ss_file}}.tsv", step=config["steps"], split=config["splits"])
    shell:
        "mkdir -p formatted/{wildcards.ss_file}; cp formatted/{wildcards.ss_file}.tsv formatted/{wildcards.ss_file}/{wildcards.ss_file}.tsv; "
        "./formatting_tools/split_file.sh formatted/{wildcards.ss_file}/{wildcards.ss_file}.tsv 16; "
        "for split in formatted/{wildcards.ss_file}/bpsplit*.tsv; do ./formatting_tools/split_file.sh $split 16; done"


# Map rsids to chr:bp location

rule retrieve_ensembl_mapping_data:
    input:
        "formatted/{ss_file}/bpsplit_{step}_bpsplit_{split}_{ss_file}.tsv"
    output:
        "formatted/{ss_file}/bpsplit_{step}_bpsplit_{split}_{ss_file}.tsv.out"
    shell:
        "./formatting_tools/var2location.pl {input}"


# Update locations based on Ensembl mapping
# Failing that --> liftover 
# Failing that --> set location to 'NA'

rule update_locations_from_ensembl:
    input:
        "formatted/{ss_file}/bpsplit_{step}_bpsplit_{split}_{ss_file}.tsv.out",
        in_ss="formatted/{ss_file}/bpsplit_{step}_bpsplit_{split}_{ss_file}.tsv"
    output:
        "build_38/{ss_file}/bpsplit_{step}_bpsplit_{split}_{ss_file}.tsv"
    params:
        to_build=config["desired_build"],
    shell:
        "filename={wildcards.ss_file}; "
        "from_build=$(echo -n $filename | tail -c 2); " 
        "python formatting_tools/update_locations.py -f {input.in_ss} -d build_38/{wildcards.ss_file} -from_build $from_build -to_build {params.to_build}"


# Concatenate all the splits

rule cat_all_splits:
    input:
        expand("build_38/{{ss_file}}/bpsplit_{step}_bpsplit_{split}_{{ss_file}}.tsv", step=config["steps"], split=config["splits"])
    output:
        "build_38/{ss_file}/{ss_file}.tsv"
    shell:
        "./formatting_tools/cat_splits_alt.sh {wildcards.ss_file}"


# Split the file by chromosome so that we know which VCF file to reference later on

rule split_by_chrom:
    input:
        "build_38/{ss_file}/{ss_file, \d+-GSCT\d+-EFO_\d+}.tsv"
    output:
        "build_38/{ss_file}/chr_{chromosome}.tsv"
    shell:
        "python formatting_tools/split_by_chromosome.py -f {input} -chr {wildcards.chromosome} -d build_38/"


# Split each chromosome file into fractions for parallelisation purposes

rule split_by_bp:
    input:
        "build_38/{ss_file, \d+-GSCT\d+-EFO_\d+}/chr_{chromosome}.tsv"
    output:
        expand("build_38/{{ss_file}}/bpsplit_{step}_chr_{{chromosome}}.tsv", step=config["steps"])
    shell:
        "./formatting_tools/split_file.sh {input} 16"


# Run sumstat_harmoniser.py to get the orientation counts for each split file

rule generate_strand_counts:
    input:
        "vcf_refs/homo_sapiens-chr{chromosome}.vcf.gz",
        "vcf_refs/homo_sapiens-chr{chromosome}.vcf.gz.tbi",
        in_ss="build_38/{ss_file}/bpsplit_{step}_chr_{chromosome}.tsv"
    output:
        "harm_splits/{ss_file}/output/strand_count_bpsplit_{step, \d+}_chr_{chromosome}.tsv"
    shell:
        "mkdir -p harm_splits/{wildcards.ss_file}/output;"
        "./formatting_tools/sumstat_harmoniser/bin/sumstat_harmoniser --sumstats {input.in_ss} "
        "--vcf vcf_refs/homo_sapiens-chr{wildcards.chromosome}.vcf.gz "
        "--chrom_col chromosome "
        "--pos_col base_pair_location "
        "--effAl_col effect_allele "
        "--otherAl_col other_allele "
        "--strand_counts harm_splits/{wildcards.ss_file}/output/strand_count_bpsplit_{wildcards.step}_chr_{wildcards.chromosome}.tsv" 
        

# Summarise the orientation of the varients of all the splits i.e. what is the consensus for the entire sumstats file?

rule make_strand_count:
    input:
        expand("harm_splits/{{ss_file}}/output/strand_count_bpsplit_{step}_chr_{chromosome}.tsv", step=config["steps"], chromosome=config["chromosomes"])
    output:
        "harm_splits/{ss_file}/output/total_strand_count.csv"
    shell:
        "python formatting_tools/sum_strand_counts.py -i harm_splits/{wildcards.ss_file}/output/ -o harm_splits/{wildcards.ss_file}/output/" 


# Run sumstat_harmoniser.py for each split based on the orientation consensus

rule run_harmonisation_per_split:
    input:
        "vcf_refs/homo_sapiens-chr{chromosome}.vcf.gz",
        "vcf_refs/homo_sapiens-chr{chromosome}.vcf.gz.tbi",
        "harm_splits/{ss_file}/output/total_strand_count.csv",
        in_ss="build_38/{ss_file}/bpsplit_{step, \d+}_chr_{chromosome}.tsv"
    output:
        "harm_splits/{ss_file}/output/bpsplit_{step, \d+}_chr_{chromosome}.output.tsv"
    shell:
        "palin_mode=$(grep palin_mode harm_splits/{wildcards.ss_file}/output/total_strand_count.csv | cut -f2 );"
        "./formatting_tools/sumstat_harmoniser/bin/sumstat_harmoniser --sumstats {input.in_ss} "
        "--vcf vcf_refs/homo_sapiens-chr{wildcards.chromosome}.vcf.gz "
        "--hm_sumstats harm_splits/{wildcards.ss_file}/output/bpsplit_{wildcards.step}_chr_{wildcards.chromosome}.output.tsv "
        "--hm_statfile harm_splits/{wildcards.ss_file}/output/bpsplit_{wildcards.step}_chr_{wildcards.chromosome}.log.tsv.gz "
        "--chrom_col chromosome "
        "--pos_col base_pair_location "
        "--effAl_col effect_allele "
        "--otherAl_col other_allele "
        "--beta_col beta "
        "--palin_mode $palin_mode"


# Concatenate harmonised splits 

rule concatenate_bp_splits:
    input:
        expand("harm_splits/{{ss_file}}/output/bpsplit_{step}_chr_{{chromosome}}.output.tsv", step=config["steps"])
    output:
        "harm_splits/{ss_file}/output/merge_chr_{chromosome}.output.tsv"
    shell:
        "./formatting_tools/cat_bpsplits.sh {wildcards.ss_file} {wildcards.chromosome}"


# Concatenate chromosomes into one file

rule concatenate_chr_splits:
    input:
        expand("harm_splits/{{ss_file}}/output/merge_chr_{chromosome}.output.tsv", chromosome=config["chromosomes"])
    output:
        "harmonised/{ss_file}.tsv"
    shell:
        "./formatting_tools/cat_chroms.sh {wildcards.ss_file}"


# Final QC: set X=23 and Y=24 and remove records with invalid data in essential fields.
