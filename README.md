# wi-nf

The variant calling pipeline for wild isolates.

### Setup

Information regarding the set of fastqs belonging to a particular isotype are organized in a json document called `isotype_set.json`. This file can be generated using `setup.nf` as follows:

```
nextflow run setup.nf
```

### Usage

```
nextflow run main.nf -resume -e.test=false
```

### Installing Telseq

```
https://gist.githubusercontent.com/danielecook/1ba4db9959cd39641857/raw/7213f6aa00cb6e643121b5a61276f19185b7d8a7/telseq.rb
```

### Loading Variant Data into bigquery

```
release_date=20170312
bq load --field_delimiter "\t" \
        --skip_leading_rows 1  \
        --ignore_unknown_values \
        andersen-lab:WI.${release_date} \
        gs://elegansvariation.org/releases/${release_date}/WI.${release_date}.tsv.gz \
        CHROM:STRING,POS:INTEGER,SAMPLE:STRING,REF:STRING,ALT:STRING,FILTER:STRING,FT:STRING,GT:STRING
```
