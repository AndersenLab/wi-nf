#!/usr/bin/env nextflow
/*
 * Authors:
 * - Daniel Cook <danielecook@gmail.com>
 *
 */


/*
    Globals
*/

// Define contigs here!
CONTIG_LIST = ["I", "II", "III", "IV", "V", "X", "MtDNA"]
contigs = Channel.from(CONTIG_LIST)

/*
    Params
*/

date = new Date().format( 'yyyyMMdd' )
params.out = "WI-${date}"
params.debug = false
params.annotation_reference = "WS263"
params.cores = 6
params.tmpdir = "tmp/"
params.email = ""
params.reference = "(required)"
params.manta_path = null
params.tiddit_discord = null
params.snpeff_path="${workflow.workDir}/snpeff"


// Compressed Reference File
File reference = new File("${params.reference}")
if (params.reference != "(required)") {
   reference_handle = reference.getAbsolutePath();
   reference_handle_uncompressed = reference_handle.replace(".gz", "")
} else {
   reference_handle = "(required)"
}

// Debug
if (params.debug == true) {
    println """

        *** Using debug mode ***

    """
    params.fqs = "${workflow.projectDir}/test_data/sample_sheet.tsv"
    params.bamdir = "${params.out}/bam"
    File fq_file = new File(params.fqs);
    params.fq_file_prefix = "${workflow.projectDir}/test_data"

    // DEBUG Filter thresholds
    min_depth=0
    qual=10
    mq=10
    dv_dp=0.0


} else {
    // The SM sheet that is used is located in the root of the git repo
    params.bamdir = "(required)"
    params.fq_file_prefix = null;
    params.fqs = "sample_sheet.tsv"

    min_depth=10
    qual=30
    mq=40
    dv_dp=0.5

}

File fq_file = new File(params.fqs);

/*
    ==
    UX
    ==
*/

param_summary = '''


     ▄         ▄  ▄▄▄▄▄▄▄▄▄▄▄                         ▄▄        ▄  ▄▄▄▄▄▄▄▄▄▄▄
    ▐░▌       ▐░▌▐░░░░░░░░░░░▌                       ▐░░▌      ▐░▌▐░░░░░░░░░░░▌
    ▐░▌       ▐░▌ ▀▀▀▀█░█▀▀▀▀                        ▐░▌░▌     ▐░▌▐░█▀▀▀▀▀▀▀▀▀
    ▐░▌       ▐░▌     ▐░▌                            ▐░▌▐░▌    ▐░▌▐░▌
    ▐░▌   ▄   ▐░▌     ▐░▌           ▄▄▄▄▄▄▄▄▄▄▄      ▐░▌ ▐░▌   ▐░▌▐░█▄▄▄▄▄▄▄▄▄
    ▐░▌  ▐░▌  ▐░▌     ▐░▌          ▐░░░░░░░░░░░▌     ▐░▌  ▐░▌  ▐░▌▐░░░░░░░░░░░▌
    ▐░▌ ▐░▌░▌ ▐░▌     ▐░▌           ▀▀▀▀▀▀▀▀▀▀▀      ▐░▌   ▐░▌ ▐░▌▐░█▀▀▀▀▀▀▀▀▀
    ▐░▌▐░▌ ▐░▌▐░▌     ▐░▌                            ▐░▌    ▐░▌▐░▌▐░▌
    ▐░▌░▌   ▐░▐░▌ ▄▄▄▄█░█▄▄▄▄                        ▐░▌     ▐░▐░▌▐░▌
    ▐░░▌     ▐░░▌▐░░░░░░░░░░░▌                       ▐░▌      ▐░░▌▐░▌
     ▀▀       ▀▀  ▀▀▀▀▀▀▀▀▀▀▀                         ▀        ▀▀  ▀


''' + """

    parameters              description                    Set/Default
    ==========              ===========                    =======

    --debug                 Set to 'true' to test          ${params.debug}
    --cores                 Regular job cores              ${params.cores}
    --out                   Directory to output results    ${params.out}
    --fqs                   fastq file (see help)          ${params.fqs}
    --fq_file_prefix        fastq prefix                   ${params.fq_file_prefix}
    --reference             Reference Genome (w/ .gz)      ${params.reference}
    --annotation_reference  SnpEff annotation              ${params.annotation_reference}
    --bamdir                Location for bams              ${params.bamdir}
    --tmpdir                A temporary directory          ${params.tmpdir}
    --email                 Email to be sent results       ${params.email}

    HELP: http://andersenlab.org/dry-guide/pipeline-wi/

"""

println param_summary

if (params.reference == "(required)" || params.fqs == "(required)") {

    println """
    The Set/Default column shows what the value is currently set to
    or would be set to if it is not specified (it's default).
    """
    System.exit(1)
}

if (!reference.exists()) {
    println """

    Error: Reference does not exist

    """
    System.exit(1)
}

if (!fq_file.exists()) {
    println """

    Error: fastq sheet does not exist

    """
    System.exit(1)
}


// Read sample sheet
strainFile = new File(params.fqs)

if (params.fq_file_prefix != "") {
    fqs = Channel.from(fq_file.collect { it.tokenize( '\t' ) })
                 .map { SM, ID, LB, fq1, fq2, seq_folder -> [SM, ID, LB, file("${params.fq_file_prefix}/${fq1}"), file("${params.fq_file_prefix}/${fq2}"), seq_folder] }
} else {
    fqs = Channel.from(fq_file.collect { it.tokenize( '\t' ) })
                 .map { SM, ID, LB, fq1, fq2, seq_folder -> [SM, ID, LB, file("${fq1}"), file("${fq2}"), seq_folder] }
}


fqs.into {
    fqs_kmer
    fqs_align
}

/*
    =============
    Kmer counting
    =============
*/
process kmer_counting {

    cpus params.cores

    tag { ID }

    input:
        set SM, ID, LB, fq1, fq2, seq_folder from fqs_kmer
    output:
        file("${ID}.kmer.tsv") into kmer_set

    """
        # fqs will have same number of lines
        export OFS="\t"
        fq_wc="`zcat ${fq1} | awk 'NR % 4 == 0' | wc -l`"
        
        zcat ${fq1} ${fq2} | \\
        fastq-kmers -k 6 | \\
        awk -v OFS="\t" -v ID=${ID} -v SM=${SM} -v fq_wc="\${fq_wc}" 'NR > 1 { print \$0, SM, ID, fq_wc }' - > ${ID}.kmer.tsv
    """
}


process merge_kmer {

    publishDir params.out + "/phenotype", mode: 'copy'

    input:
        file("kmer*.tsv") from kmer_set.collect()
    output:
        file("kmers.tsv")

    """
        cat <(echo "kmer\tfrequency\tSM\tID\twc") *.tsv > kmers.tsv
    """

}


/*
    ===============
    Fastq alignment
    ===============

    The output looks strange below,
    but its designed to group like samples together - so leave it!

*/

process perform_alignment {

    cpus params.cores

    tag { ID }

    input:
        set SM, ID, LB, fq1, fq2, seq_folder from fqs_align
    output:
        set val(SM), file("${ID}.bam"), file("${ID}.bam.bai") into fq_bam_set


    """
        bwa mem -t ${task.cpus} -R '@RG\\tID:${ID}\\tLB:${LB}\\tSM:${SM}' ${reference_handle} ${fq1} ${fq2} | \\
        sambamba view --nthreads=${task.cpus} --show-progress --sam-input --format=bam --with-header /dev/stdin | \\
        sambamba sort --nthreads=${task.cpus} --show-progress --tmpdir=${params.tmpdir} --out=${ID}.bam /dev/stdin
        sambamba index --nthreads=${task.cpus} ${ID}.bam

        if [[ ! \$(samtools view ${ID}.bam | head -n 10) ]]; then
            exit 1;
        fi

    """
}

/*
    ===================================
    Merge - Generate isotype-level BAMs
    ===================================
*/

process merge_bam {

    cpus params.cores

    tag { SM }

    input:
        set SM, bam, index from fq_bam_set.groupTuple()

    output:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") into SM_bam_set
        file("${SM}.picard.sam.markduplicates") into duplicates_set

    """
    count=`echo ${bam.join(" ")} | tr ' ' '\\n' | wc -l`

    if [ "\${count}" -eq "1" ]; then
        ln -s ${bam.join(" ")} ${SM}.merged.bam
        ln -s ${bam.join(" ")}.bai ${SM}.merged.bam.bai
    else
        sambamba merge --nthreads=${task.cpus} --show-progress ${SM}.merged.bam ${bam.join(" ")}
        sambamba index --nthreads=${task.cpus} ${SM}.merged.bam
    fi

    picard MarkDuplicates I=${SM}.merged.bam O=${SM}.bam M=${SM}.picard.sam.markduplicates VALIDATION_STRINGENCY=SILENT REMOVE_DUPLICATES=false
    sambamba index --nthreads=${task.cpus} ${SM}.bam
    """
}

SM_bam_set.into {
                  bam_publish;
                  bam_idxstats;
                  bam_stats;
                  bam_coverage;
                  bam_snp_individual;
                  bam_snp_union;
                  bam_telseq;
                  bam_isotype_stats;
                  bam_manta;
                  bam_tiddit;
                  bam_delly;
                  bam_delly_recall;
}

process bam_isotype_stats {

    cpus params.cores

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_isotype_stats

    output:
         file("${SM}.samtools.txt") into SM_samtools_stats_set
         file("${SM}.bamtools.txt") into SM_bamtools_stats_set
         file("${SM}_fastqc.zip") into SM_fastqc_stats_set
         file("${SM}.picard.*") into SM_picard_stats_set

    """
        samtools stats --threads=${task.cpus} ${SM}.bam > ${SM}.samtools.txt
        bamtools -in ${SM}.bam > ${SM}.bamtools.txt
        fastqc --threads ${task.cpus} ${SM}.bam
        picard CollectAlignmentSummaryMetrics R=${reference_handle} I=${SM}.bam O=${SM}.picard.alignment_metrics.txt
        picard CollectInsertSizeMetrics I=${SM}.bam O=${SM}.picard.insert_metrics.txt H=${SM}.picard.insert_histogram.txt
    """

}

process bam_publish {

    publishDir "${params.bamdir}/WI/isotype", mode: 'copy', pattern: '*.bam*'

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_publish
    output:
        set file("${SM}.bam"), file("${SM}.bam.bai")

    """
        echo "${SM} saved to publish folder you rockstar."
    """
}

process SM_idx_stats {

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_idxstats
    output:
        file("${SM}.bam_idxstats") into bam_idxstats_set
        file("${SM}.bam_idxstats") into bam_idxstats_multiqc

    """
        samtools idxstats ${SM}.bam | awk '{ print "${SM}\\t" \$0 }' > ${SM}.bam_idxstats
    """
}

process SM_combine_idx_stats {

    publishDir params.out + "/alignment", mode: 'copy'

    input:
        val bam_idxstats from bam_idxstats_set.toSortedList()

    output:
        file("isotype_bam_idxstats.tsv")

    """
        echo -e "SM\\treference\\treference_length\\tmapped_reads\\tunmapped_reads" > isotype_bam_idxstats.tsv
        cat ${bam_idxstats.join(" ")} >> isotype_bam_idxstats.tsv
    """
}

/*
    =================
    Isotype BAM stats
    =================
*/

process isotype_bam_stats {

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_stats

    output:
        file 'bam_stat' into SM_bam_stat_files

    """
        samtools stats ${SM}.bam | \\
        grep ^SN | \\
        cut -f 2- | \\
        awk '{ print "${SM}\t" \$0 }' | \\
        sed 's/://g' > bam_stat
    """
}

process combine_isotype_bam_stats {

    publishDir params.out + "/alignment", mode: 'copy'

    input:
        val stat_files from SM_bam_stat_files.toSortedList()

    output:
        file("isotype_bam_stats.tsv")

    """
        echo -e "fq_pair_id\\tvariable\\tvalue\\tcomment" > isotype_bam_stats.tsv
        cat ${stat_files.join(" ")} >> SM_stats.tsv
    """
}

/*
    ============
    Coverage BAM
    ============
*/
process coverage_SM {

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_coverage

    output:
        val SM into isotype_coverage_sample
        file("${SM}.coverage.tsv") into isotype_coverage


    """
        bam coverage ${SM}.bam > ${SM}.coverage.tsv
    """
}

process coverage_SM_merge {

    publishDir "${params.out}/alignment", mode: 'copy'

    input:
        val sm_set from isotype_coverage.toSortedList()

    output:
        file("isotype_coverage.full.tsv") into mt_content
        file("isotype_coverage.tsv") into isotype_coverage_merged

    """
        echo -e 'bam\\tcontig\\tstart\\tend\\tproperty\\tvalue' > isotype_coverage.full.tsv
        cat ${sm_set.join(" ")} >> isotype_coverage.full.tsv

        # Generate condensed version
        cat <(echo -e 'strain\\tcoverage') <(cat isotype_coverage.full.tsv | grep 'genome' | grep 'depth_of_coverage' | cut -f 1,6) > isotype_coverage.tsv
    """
}

/*
    ==========
    MT content
    ==========
*/

process output_mt_content {

    executor 'local'

    publishDir params.out + "/phenotype", mode: 'copy'

    input:
        file("isotype_coverage.full.tsv") from mt_content

    output:
        file("MT_content.tsv")

    """
        cat <(echo -e 'isotype\\tmt_content') <(cat isotype_coverage.full.tsv | awk '/mt_nuclear_ratio/' | cut -f 1,6) > MT_content.tsv
    """
}

/*
    ======
    telseq
    ======
*/

process call_telseq {

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_telseq
    output:
        file("telseq_out.txt") into telseq_results

    """
        telseq -z TTAGGC -H ${SM}.bam > telseq_out.txt
    """
}

process combine_telseq {

    executor 'local'

    publishDir params.out + "/phenotype", mode: 'copy'

    input:
        file("ind_telseq?.txt") from telseq_results.toSortedList()

    output:
        file("telseq.tsv")

    '''
        telseq -h > telseq.tsv
        cat ind_telseq*.txt | egrep -v '\\[|BAMs' >> telseq.tsv
    '''
}

/*
    ========================
    Call Variants - BCFTools
    ========================    
*/

process call_variants {

    tag { SM }

    cpus params.cores

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_snp_individual

    output:
        file("${SM}.vcf.gz") into isotype_vcf

    """

    # Subsample high-depth bams
    coverage=`goleft covstats ${SM}.bam | awk 'NR > 1 { printf "%5.0f", \$1 }'`

    if [ \${coverage} -gt 100 ];
    then

        # Add a trap to remove temp files
        function finish {
            rm -f "${SM}.subsample.bam"
            rm -f "${SM}.subsample.bam.bai"
        }
        trap finish EXIT

        echo "Coverage is above 100x; Subsampling to 100x"
        # Calculate fraction of reads to keep
        frac_keep=`echo "100.0 / \${coverage}" | bc -l | awk '{printf "%0.2f", \$0 }'`
        SM_use="${SM}.subsample.bam"
        sambamba view --nthreads=${task.cpus} --show-progress --format=bam --with-header --subsample=\${frac_keep} ${SM}.bam > \${SM_use}
        sambamba index --nthreads ${task.cpus} \${SM_use}
    else
        echo "Coverage is below 100x; No subsampling"
        SM_use="${SM}.bam"
    fi;


    function process_variants {
        bcftools mpileup --redo-BAQ \\
                         --redo-BAQ \\
                         -r \$1 \\
                         --gvcf 1 \\
                         --annotate DP,AD,ADF,ADR,INFO/AD,SP \\
                         --fasta-ref ${reference_handle} \${SM_use} | \\
        bcftools call --multiallelic-caller \\
                      --gvcf 3 \\
                      --multiallelic-caller -O v - | \\
        vk geno het-polarization - | \\
        bcftools filter -O u --mode + --soft-filter quality --include "(QUAL >= ${qual}) || (FORMAT/GT == '0/0') || (TYPE == 'REF')" |  \\
        bcftools filter -O u --mode + --soft-filter min_depth --include "(FORMAT/DP > ${min_depth}) || (TYPE == 'REF')" | \\
        bcftools filter -O u --mode + --soft-filter mapping_quality --include "(INFO/MQ > ${mq}) || (TYPE == 'REF')" | \\
        bcftools filter -O v --mode + --soft-filter dv_dp --include "((FORMAT/AD[*:1])/(FORMAT/DP) >= ${dv_dp}) || (FORMAT/GT == '0/0') || (TYPE == 'REF')" | \\
        awk -v OFS="\\t" '\$0 ~ "^#" { print } \$0 ~ ":AB" { gsub("PASS","", \$7); if (\$7 == "") { \$7 = "het"; } else { \$7 = \$7 ";het"; } } \$0 !~ "^#" { print }' | \\
        awk -v OFS="\\t" '\$0 ~ "^#CHROM" { print "##FILTER=<ID=het,Description=\\"heterozygous_call_after_het_polarization\\">"; print; } \$0 ~ "^#" && \$0 !~ "^#CHROM" { print } \$0 !~ "^#" { print }' | \\
        vk geno transfer-filter - | \\
        bcftools norm -O z --check-ref s --fasta-ref ${reference_handle} > ${SM}.\$1.vcf.gz
    }

    export SM_use;
    export -f process_variants

    contigs="`samtools view -H ${SM}.bam | grep -Po 'SN:([^\\W]+)' | cut -c 4-40`"
    parallel -j ${task.cpus} --verbose process_variants {} ::: \${contigs}
    order=`echo \${contigs} | tr ' ' '\\n' | awk '{ print "${SM}." \$1 ".vcf.gz" }'`
    
    # Concatenate and filter
    bcftools concat --threads ${task.cpus-1} \${order} -O z > ${SM}.vcf.gz
    bcftools index --threads ${task.cpus} ${SM}.vcf.gz
    rm \${order}

    """
}


process generate_vcf_list {

    executor 'local'

    cpus 1 

    input:
       val vcf_set from isotype_vcf.toSortedList()

    output:
       file("union_vcfs.txt") into union_vcfs

    """
        echo ${vcf_set.join(" ")} | tr ' ' '\\n' > union_vcfs.txt
    """
}

union_vcfs_in = union_vcfs.spread(contigs)

process merge_union_vcf_chromosome {

    cpus params.cores

    tag { chrom }

    input:
        set file(union_vcfs:"union_vcfs.txt"), val(chrom) from union_vcfs_in

    output:
        set val(chrom), file("${chrom}.merged.vcf.gz"), file("${chrom}.merged.vcf.gz.csi") into raw_vcf

    """
        bcftools merge --threads ${task.cpus-5} \\
                       --gvcf ${reference_handle} \\
                       --regions ${chrom} \\
                       -O z \\
                       -m both \\
                       --file-list ${union_vcfs} > ${chrom}.merged.vcf.gz
        bcftools index --threads ${task.cpus-1} ${chrom}.merged.vcf.gz
    """
}


// Generates the initial soft-vcf; but it still
// needs to be annotated with snpeff and annovar.
process generate_soft_vcf {

    cpus params.cores

    tag { chrom }

    input:
        set val(chrom), file("${chrom}.merged.vcf.gz"), file("${chrom}.merged.vcf.gz.csi") from raw_vcf

    output:
        set val(chrom), file("${chrom}.soft-filter.vcf.gz"), file("${chrom}.soft-filter.vcf.gz.csi") into soft_filtered_vcf

    """
        bcftools view --threads=${task.cpus-1} ${chrom}.merged.vcf.gz | \\
        vk filter MISSING --max=0.90 --soft-filter="high_missing" --mode=x - | \
        vk filter HET --max=0.10 --soft-filter="high_heterozygosity" --mode=+ - | \
        vk filter REF --min=1 - | \
        vk filter ALT --min=1 - | \
        vcffixup - | \\
        bcftools view --threads=${task.cpus-1} -O z - > ${chrom}.soft-filter.vcf.gz
        bcftools index --threads=${task.cpus} -f ${chrom}.soft-filter.vcf.gz
    """
}


/*
    Fetch some necessary datasets
*/

process fetch_ce_gff {

    executor 'local'

    output:
        file("ce.gff3.gz") into ce_gff3
    
    """
        # Download the annotation file
        wget -O ce.gff3.gz ftp://ftp.ensembl.org/pub/current_gff3/caenorhabditis_elegans/Caenorhabditis_elegans.WBcel235.91.gff3.gz
    """
}


fix_snpeff_script = file("fix_snpeff_names.py")

process fetch_gene_names {

    executor 'local'

    output:
        file("gene.pkl") into gene_pkl

    """
    fix_snpeff_names.py
    """

}

gene_pkl.into {
                    gene_pkl_snpindel;
                    gene_pkl_manta;
                    gene_pkl_delly;
                    gene_pkl_tiddit;
                    gene_pkl_cnv;
                    gene_pkl_svdb;
              }


process annotate_vcf {

    cpus params.cores

    tag { chrom }

    errorStrategy 'retry'
    maxRetries 2

    input:
        set val(chrom), file("${chrom}.soft-filter.vcf.gz"), file("${chrom}.soft-filter.vcf.gz.csi") from soft_filtered_vcf
        file("gene.pkl") from gene_pkl_snpindel
        file("ce.gff3.gz") from ce_gff3

    output:
        file("${chrom}.soft-annotated.vcf.gz") into soft_annotated_vcf
        file("snpeff_out.csv") into snpeff_multiqc


    """
        # bcftools csq
        bcftools view --threads=${task.cpus-1} -O v ${chrom}.soft-filter.vcf.gz | \\
        bcftools csq -O v --fasta-ref ${reference_handle} \\
                     --gff-annot ce.gff3.gz \\
                     --phase a | \\
        snpEff eff -csvStats snpeff_out.csv \\
        -no-downstream \\
        -no-intergenic \\
        -no-upstream \\
        -dataDir ${workflow.projectDir}/snpeff \\
        -config ${workflow.projectDir}/snpeff/snpEff.config \\
        ${params.annotation_reference} | \\
        bcftools view -O v | \\
        python `which fix_snpeff_names.py` - | \\
        bcftools view --threads=${task.cpus-1} -O z > ${chrom}.soft-annotated.vcf.gz
        bcftools index --threads=${task.cpus} ${chrom}.soft-annotated.vcf.gz
    """

}


// Generate a list of ordered files.
contig_raw_vcf = CONTIG_LIST*.concat(".soft-annotated.vcf.gz")

process concatenate_union_vcf {

    cpus params.cores

    tag { chrom }

    input:
        val merge_vcf from soft_annotated_vcf.toSortedList()

    output:
        set file("soft-filter.vcf.gz"), file("soft-filter.vcf.gz.csi") into soft_filtered_concatenated
        set val("soft"), file("soft-filter.vcf.gz"), file("soft-filter.vcf.gz.csi") into soft_sample_summary

    """
        for i in ${merge_vcf.join(" ")}; do
            ln  -s \${i} `basename \${i}`;
        done;
        chrom_set="";
        bcftools concat --threads ${task.cpus-1} -O z ${contig_raw_vcf.join(" ")} > soft-filter.vcf.gz
        bcftools index  --threads ${task.cpus} soft-filter.vcf.gz
    """
}




soft_filtered_concatenated.into {
                    filtered_to_annovar;
                    filtered_vcf_to_hard;
                    filtered_vcf_gtcheck;
                    filtered_vcf_primer;
                  }




process generate_hard_vcf {

    cpus params.cores

    publishDir params.out + "/variation", mode: 'copy'

    input:
        set file("WI.${date}.soft-filter.vcf.gz"), file("WI.${date}.soft-filter.vcf.gz.csi") from filtered_vcf_to_hard

    output:
        set file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi") into hard_vcf
        set val('clean'), file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi") into hard_vcf_summary
        set val("hard"), file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi") into hard_sample_summary
        file("WI.${date}.hard-filter.vcf.gz.tbi")
        file("WI.${date}.hard-filter.stats.txt") into hard_filter_stats


    """
        # Generate hard-filtered (clean) vcf
        bcftools view WI.${date}.soft-filter.vcf.gz | \\
        bcftools filter --set-GTs . --exclude 'FORMAT/FT != "PASS"' | \\
        vk filter MISSING --max=${params.missing} - | \\
        vk filter HET --max=0.10 - | \\
        vk filter REF --min=1 - | \\
        vk filter ALT --min=1 - | \\
        vcffixup - | \\
        bcftools view --trim-alt-alleles -O z > WI.${date}.hard-filter.vcf.gz
        bcftools index -f WI.${date}.hard-filter.vcf.gz
        tabix WI.${date}.hard-filter.vcf.gz
        bcftools stats --verbose WI.${date}.hard-filter.vcf.gz > WI.${date}.hard-filter.stats.txt
    """
}

hard_vcf.into { 
                hard_vcf_to_impute;
                tajima_bed;
                vcf_phylo;
                hard_vcf_variant_accumulation;
            }


process calculate_gtcheck {

    publishDir params.out + "/concordance", mode: 'copy'

    input:
        set file("WI.${date}.soft-filter.vcf.gz"), file("WI.${date}.soft-filter.vcf.gz.csi") from filtered_vcf_gtcheck

    output:
        file("gtcheck.tsv") into gtcheck

    """
        echo -e "discordance\\tsites\\tavg_min_depth\\ti\\tj" > gtcheck.tsv
        bcftools gtcheck -H -G 1 WI.${date}.soft-filter.vcf.gz | egrep '^CN' | cut -f 2-6 >> gtcheck.tsv
    """
}


/*
    =================
    Calculate Summary
    =================
*/
process calculate_hard_vcf_summary {

    publishDir params.out + "/variation", mode: 'copy'

    input:
        set val('clean'), file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi") from hard_vcf_summary

    output:
        file("WI.${date}.hard-filter.genotypes.tsv")
        file("WI.${date}.hard-filter.genotypes.frequency.tsv")

    """
        # Calculate singleton freq
        vk calc genotypes WI.${date}.hard-filter.vcf.gz > WI.${date}.hard-filter.genotypes.tsv
        vk calc genotypes --frequency WI.${date}.hard-filter.vcf.gz > WI.${date}.hard-filter.genotypes.frequency.tsv

        # Calculate average discordance; Determine most diverged strains
        awk '\$0 ~ "^CN" { print 1-(\$2/\$3) "\t" \$5 "\n" 1-(\$2/\$3) "\t" \$6 }' | \
        sort -k 2 | \
        datamash mean 1 --group 2 | \
        sort -k2,2n > WI.${date}.hard-filter.avg_concordance.tsv
    """
}


/*
    Variant summary
*/

sample_summary = soft_sample_summary.concat( hard_sample_summary )

process sample_variant_summary {

    publishDir "${params.out}/variation", mode: 'copy'

    input:
        set val(summary_vcf), file("out.vcf.gz"), file("out.vcf.gz.csi") from sample_summary

    output:
        file("${summary_vcf}.variant_summary.json")

    """
    python sample_summary_vcf.py out.vcf.gz > ${summary_vcf}.variant_summary.json
    """
}

/*
    ==============
    Phylo analysis
    ==============
*/
process phylo_analysis {

    publishDir "${params.out}/popgen/trees", mode: "copy"

    tag { contig }

    input:
        set file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi"), val(contig) from vcf_phylo.spread(["I", "II", "III", "IV", "V", "X", "MtDNA", "genome"])

    output:
        set val(contig), file("${contig}.tree") into trees

    """
        if [ "${contig}" == "genome" ]
        then
            vk phylo tree nj WI.${date}.hard-filter.vcf.gz > genome.tree
            if [[ ! genome.tree ]]; then
                exit 1;
            fi
        else
            vk phylo tree nj WI.${date}.hard-filter.vcf.gz ${contig} > ${contig}.tree
            if [[ ! ${contig}.tree ]]; then
                exit 1;
            fi
        fi
    """
}


process plot_trees {

    publishDir "${params.out}/popgen/trees", mode: "copy"

    tag { contig }

    input:
        set val(contig), file("${contig}.tree") from trees

    output:
        file("${contig}.pdf")
        file("${contig}.png")


    """
        Rscript --vanilla `which process_trees.R` ${contig}
    """

}


process tajima_bed {

    publishDir "${params.out}/popgen", mode: 'copy'

    input:
        set file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi") from tajima_bed
    output:
        set file("WI.${date}.tajima.bed.gz"), file("WI.${date}.tajima.bed.gz.tbi")

    """
        vk tajima --no-header 100000 10000 WI.${date}.hard-filter.vcf.gz | bgzip > WI.${date}.tajima.bed.gz
        tabix WI.${date}.tajima.bed.gz
    """

}


/*
    ====================
    variant_accumulation
    ====================
*/

process calc_variant_accumulation {

    publishDir "${params.out}/popgen", mode: 'copy'

    input: 
        set file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi") from hard_vcf_variant_accumulation

    output:
        file("variant_accumulation.pdf")

    """
    bcftools query -f "[%GT\t]\n" WI.${date}.hard-filter.vcf.gz  | \
    awk '{ gsub(":GT", "", \$0); gsub("(# )?\\[[0-9]+\\]","",\$0); print \$0 }' | \\
    sed 's/0\\/0/0/g' | \\
    sed 's/1\\/1/1/g' | \\
    sed 's/0\\/1/NA/g' | \\
    sed 's/1\\/0/NA/g' | \\
    sed 's/.\\/./NA/g' | \\
    gzip > impute_gts.tsv.gz

    Rscript --vanilla `which variant_accumulation.R`
    """
}


process imputation {

    cpus params.cores

    publishDir params.out + "/variation", mode: 'copy'


    input:
        set file("WI.${date}.hard-filter.vcf.gz"), file("WI.${date}.hard-filter.vcf.gz.csi") from hard_vcf_to_impute
    output:
        set file("WI.${date}.impute.vcf.gz"), file("WI.${date}.impute.vcf.gz.csi") into impute_vcf
        file("WI.${date}.impute.stats.txt") into impute_stats
        file("WI.${date}.impute.stats.txt") into filtered_stats
        file("WI.${date}.impute.vcf.gz")
        file("WI.${date}.impute.vcf.gz.tbi")

    """
        beagle nthreads=${task.cpus} window=8000 overlap=3000 impute=true ne=17500 gt=WI.${date}.hard-filter.vcf.gz out=WI.${date}.impute
        bcftools index --threads=${task.cpus} WI.${date}.impute.vcf.gz
        tabix WI.${date}.impute.vcf.gz
        bcftools stats --verbose WI.${date}.impute.vcf.gz > WI.${date}.impute.stats.txt
    """
}


impute_vcf.into { kinship_vcf;  mapping_vcf; haplotype_vcf }


process make_kinship {

    publishDir params.out + "/cegwas", mode: 'copy'

    input:
        set file("WI.${date}.impute.vcf.gz"), file("WI.${date}.impute.vcf.gz.csi") from kinship_vcf
    output:
        file("kinship.Rda")

    """
        Rscript -e 'library(cegwas); kinship <- generate_kinship("WI.${date}.impute.vcf.gz"); save(kinship, file = "kinship.Rda");'
    """

}


process make_mapping_rda_file {

    publishDir params.out + "/cegwas", mode: 'copy'

    input:
        set file("WI.${date}.impute.vcf.gz"), file("WI.${date}.impute.vcf.gz.csi") from mapping_vcf
    output:
        file("snps.Rda")

    """
        Rscript -e 'library(cegwas); snps <- generate_mapping("WI.${date}.impute.vcf.gz"); save(snps, file = "snps.Rda");'
    """

}


/*
    Haplotype analysis
*/

process_ibd=file("process_ibd.R")

minalleles = 0.05 // Species the minimum number of samples carrying the minor allele.
r2window = 1500 // Specifies the number of markers in the sliding window used to detect correlated markers.
ibdtrim = 0
r2max = 0.8

process ibdseq {

    publishDir params.out + "/haplotype", mode: 'copy'

    tag { "ibd" }

    input:
        set file("WI.${date}.impute.vcf.gz"), file("WI.${date}.impute.vcf.gz.csi") from haplotype_vcf

    output:
        file("haplotype_length.png")
        file("max_haplotype_sorted_genome_wide.png")
        file("haplotype.png")
        file("sweep_summary.tsv")
        file("processed_haps.Rda")

    """
    minalleles=\$(bcftools query --list-samples WI.${date}.impute.vcf.gz | wc -l | awk '{ print \$0*${minalleles} }' | awk '{printf("%d\\n", \$0+=\$0<0?0:0.9)}')
    if [[ \${minalleles} -lt 2 ]];
    then
        minalleles=2;
    fi;
    echo "minalleles=${minalleles}"
    for chrom in I II III IV V X; do
        java -jar `which ibdseq.r1206.jar` \\
            gt=WI.${date}.impute.vcf.gz \\
            out=haplotype_\${chrom} \\
            ibdtrim=${ibdtrim} \\
            minalleles=\${minalleles} \\
            r2max=${r2max} \\
            nthreads=4 \\
            chrom=\${chrom}
        done;
    cat *.ibd | awk '{ print \$0 "\\t${minalleles}\\t${ibdtrim}\\t${r2window}\\t${r2max}" }' > haplotype.tsv
    Rscript --vanilla `which process_ibd.R`
    """
}



process download_annotation_files {

    executor 'local'

    errorStrategy 'retry'
    maxRetries 5

    output:
        set val("phastcons"), file("elegans.phastcons.wib") into phastcons
        set val("phylop"), file("elegans.phylop.wib") into phylop
        set val("repeatmasker"), file("elegans_repeatmasker.bb") into repeatmasker

    """
        wget ftp://ftp.wormbase.org/pub/wormbase/releases/WS258/MULTI_SPECIES/hub/elegans/elegans.phastcons.wib
        wget ftp://ftp.wormbase.org/pub/wormbase/releases/WS258/MULTI_SPECIES/hub/elegans/elegans.phylop.wib
        wget ftp://ftp.wormbase.org/pub/wormbase/releases/WS258/MULTI_SPECIES/hub/elegans/elegans_repeatmasker.bb
    """
}

phastcons.mix(phylop).set { wig }

process wig_to_bed {

    tag { track_name }

    publishDir params.out + '/tracks', mode: 'copy'

    input:
        set val(track_name), file("track.wib") from wig
    output:
        file("${track_name}.bed.gz") into bed_tracks
        file("${track_name}.bed.gz.tbi") into bed_indices

    """
        bigWigToBedGraph track.wib ${track_name}.bed
        bgzip ${track_name}.bed
        tabix ${track_name}.bed.gz
    """

}


process annovar_and_output_soft_filter_vcf {

    publishDir params.out + "/variation", mode: 'copy'

    cpus params.cores

    input:
        set file("WI.${date}.soft-effect.vcf.gz"), file("WI.${date}.soft-effect.vcf.gz.csi") from filtered_to_annovar
        file(track) from bed_tracks.toSortedList()
        file(track) from bed_indices.toSortedList()
        file('vcf_anno.conf') from Channel.fromPath("vcfanno.conf")

    output:
        set file("WI.${date}.soft-filter.vcf.gz"), file("WI.${date}.soft-filter.vcf.gz.csi"), file("WI.${date}.soft-filter.vcf.gz.tbi") into soft_filter_vcf
        file("WI.${date}.soft-filter.stats.txt") into soft_filter_stats

    """
        vcfanno -p ${task.cpus} vcf_anno.conf WI.${date}.soft-effect.vcf.gz | \\
        bcftools view --threads ${task.cpus-1} -O z > WI.${date}.soft-filter.vcf.gz
        bcftools index --threads ${task.cpus} WI.${date}.soft-filter.vcf.gz
        tabix WI.${date}.soft-filter.vcf.gz
        bcftools stats --verbose WI.${date}.soft-filter.vcf.gz > WI.${date}.soft-filter.stats.txt
    """

}

soft_filter_vcf.into {
                        soft_filter_vcf_strain;
                        soft_filter_vcf_isotype_list;
                        soft_filter_vcf_mod_tracks;
                        soft_filter_vcf_tsv
                     }


mod_tracks = Channel.from(["LOW", "MODERATE", "HIGH", "MODIFIER"])
soft_filter_vcf_mod_tracks.spread(mod_tracks).set { mod_track_set }


process generate_mod_tracks {

    publishDir params.out + '/tracks', mode: 'copy'

    tag { severity }

    input:
        set file("WI.${date}.vcf.gz"), file("WI.${date}.vcf.gz.csi"), file("WI.${date}.vcf.gz.tbi"), val(severity) from mod_track_set
    output:
        set file("${date}.${severity}.bed.gz"), file("${date}.${severity}.bed.gz.tbi")

    """
        bcftools view --apply-filters PASS WI.${date}.vcf.gz | \
        grep ${severity} | \
        awk '\$0 !~ "^#" { print \$1 "\\t" (\$2 - 1) "\\t" (\$2)  "\\t" \$1 ":" \$2 "\\t0\\t+"  "\\t" \$2 - 1 "\\t" \$2 "\\t0\\t1\\t1\\t0" }' | \\
        bgzip  > ${date}.${severity}.bed.gz
        tabix -p bed ${date}.${severity}.bed.gz
    """
}

process generate_strain_list {

    executor 'local'

    input:
        set file("WI.${date}.vcf.gz"), file("WI.${date}.vcf.gz.csi"), file("WI.${date}.vcf.gz.tbi") from soft_filter_vcf_isotype_list

    output:
        file('isotype_list.tsv') into isotype_list

    """
        bcftools query -l WI.${date}.vcf.gz > isotype_list.tsv
    """

}


isotype_list.splitText() { it.strip() } .spread(soft_filter_vcf_strain).into { isotype_set_vcf; isotype_set_tsv }


process generate_isotype_vcf {

    publishDir params.out + '/isotype/vcf', mode: 'copy'

    tag { isotype }

    input:
        set val(isotype), file("WI.${date}.vcf.gz"), file("WI.${date}.vcf.gz.csi"), file("WI.${date}.vcf.gz.tbi") from isotype_set_vcf

    output:
        set val(isotype), file("${isotype}.${date}.vcf.gz"), file("${isotype}.${date}.vcf.gz.tbi") into isotype_ind_vcf

    """
        bcftools view -O z --samples ${isotype} --exclude-uncalled WI.${date}.vcf.gz  > ${isotype}.${date}.vcf.gz && tabix ${isotype}.${date}.vcf.gz
    """

}


process generate_isotype_tsv {

    publishDir params.out + '/isotype/tsv', mode: 'copy'

    tag { isotype }

    input:
        set val(isotype), file("WI.${date}.vcf.gz"), file("WI.${date}.vcf.gz.csi"), file("WI.${date}.vcf.gz.tbi") from isotype_set_tsv

    output:
        set val(isotype), file("${isotype}.${date}.tsv.gz")

    """
        echo 'CHROM\\tPOS\\tREF\\tALT\\tFILTER\\tFT\\tGT' > ${isotype}.${date}.tsv
        bcftools query -f '[%CHROM\\t%POS\\t%REF\\t%ALT\t%FILTER\\t%FT\\t%TGT]\\n' --samples ${isotype} WI.${date}.vcf.gz > ${isotype}.${date}.tsv
        bgzip ${isotype}.${date}.tsv
        tabix -S 1 -s 1 -b 2 -e 2 ${isotype}.${date}.tsv.gz
    """

}

vcf_stats = soft_filter_stats.concat ( hard_filter_stats, impute_stats )


/*
    Manta-sv
*/

process manta_call {
    
    tag { SM }

    
    when:
        params.manta_path

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_manta

    output:
        file "*.vcf.gz" into individual_output_vcf_zipped
        file "*.vcf.gz.tbi" into individual_output_index
        set val(SM), file("${SM}_manta.vcf") into manta_to_db


    """
        configManta.py \\
        --bam ${SM}.bam \\
        --referenceFasta ${reference_handle_uncompressed} \\
        --outputContig \\
        --runDir results/

        python results/runWorkflow.py -m local -j 8

        cp results/results/variants/diploidSV.vcf.gz .
        cp results/results/variants/diploidSV.vcf.gz.tbi .

        mv diploidSV.vcf.gz ${SM}_manta.vcf.gz 
        mv diploidSV.vcf.gz.tbi ${SM}_manta.vcf.gz.tbi

        bcftools view -Ov -o ${SM}_manta.vcf ${SM}_manta.vcf.gz 
    """

}

individual_output_vcf_zipped
  .toSortedList()
  .set { merged_deletion_vcf }


individual_output_index
  .toSortedList()
  .set { merged_vcf_index }


process merge_manta_vcf {

    publishDir params.out + "/variation", mode: 'copy'

    when:
        params.manta_path

    input:
      file merged_deletion_vcf
      file merged_vcf_index

    output:
      set file("WI.${date}.MANTAsv.soft-filter.vcf.gz"), file("WI.${date}.MANTAsv.soft-filter.vcf.gz.csi") into processed_manta_vcf
      file("WI.${date}.MANTAsv.soft-filter.stats.txt") into bcf_manta_stats

    """
        bcftools merge -m all --threads ${task.cpus-1} -o WI.${date}.MANTAsv.soft-filter.vcf.gz -Oz ${merged_deletion_vcf}
        bcftools index --threads ${task.cpus} -f WI.${date}.MANTAsv.soft-filter.vcf.gz
        bcftools stats --verbose WI.${date}.MANTAsv.soft-filter.vcf.gz > WI.${date}.MANTAsv.soft-filter.stats.txt
    """

}

process prune_manta {
    
    publishDir params.out + "/variation", mode: 'copy'

    input:
        set file(mantavcf), file(mantaindex) from processed_manta_vcf
        file("gene.pkl") from gene_pkl_manta

    output:
        set file("WI.${date}.MANTAsv.LargeRemoved.snpeff.vcf.gz"), file("WI.${date}.MANTAsv.LargeRemoved.snpeff.vcf.gz.csi") into snpeff_manta_vcf
        file("WI.${date}.MANTAsv.CONTIGS.tsv.gz") into manta_contigs
        file("MANTAsv_snpeff_out.csv") into manta_snpeff_multiqc

    """
        bcftools plugin setGT -Oz -o manta_gt_filled.vcf.gz -- ${mantavcf} -t . -n 0
        bcftools query -l manta_gt_filled.vcf.gz | sort > sample_names.txt
        bcftools view --samples-file=sample_names.txt -Oz -o manta_gt_filled_sorted.vcf.gz manta_gt_filled.vcf.gz

        bcftools view manta_gt_filled_sorted.vcf.gz | \\
        bcftools filter -e 'INFO/SVLEN>100000' | \\
        bcftools filter -e 'INFO/SVLEN<-100000' | \\
        bcftools view -Oz -o manta_gt_filled_sorted_largeRemoved.vcf.gz

        bcftools view -O v manta_gt_filled_sorted_largeRemoved.vcf.gz | \\
        snpEff eff -csvStats MANTAsv_snpeff_out.csv \\
        -no-downstream -no-intergenic -no-upstream \\
        -dataDir ${params.snpeff_path} \\
        -config ${params.snpeff_path}/snpEff.config \\
        ${params.annotation_reference} | \\
        bcftools view -O v | \\
        python `which fix_snpeff_names.py` - | \\
        bcftools view -O z > WI.${date}.MANTAsv.LargeRemoved.snpeff.vcf.gz

        bcftools index -f WI.${date}.MANTAsv.LargeRemoved.snpeff.vcf.gz

        bcftools query -f '%CHROM\\t%POS\\t%END\\t%SVTYPE\\t%SVLEN\\t%CONTIG[\\t%GT]\\n' WI.${date}.MANTAsv.LargeRemoved.snpeff.vcf.gz > WI.${date}.MANTAsv.CONTIGS.tsv

        bgzip  WI.${date}.MANTAsv.CONTIGS.tsv
    """

}

/*
    ========
    Delly-sv
    ========
*/

process delly_sv {

    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_delly

    output:
        file "*.bcf" into dellybcf


    """
        delly call ${SM}.bam -g ${reference_handle_uncompressed} -o ${SM}.bcf
    """

}

dellybcf
    .toSortedList()
    .set { deletion_bcf }

process combine_delly {
      
  input:
    file deletion_bcf

  output:
    file "*.bcf" into combined_delly_bcf


  script:
    """
        delly merge ${deletion_bcf} -m 100 -n 100000 -b 500 -r 0.5 -o WI.delly.first.bcf
    """

}

process recall_deletions {
        
    tag { SM }
    
    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_delly_recall
        file combined_delly_bcf

    output:
        file "${SM}_second.bcf" into recalled_delly_sv
        file "${SM}_second.bcf.csi" into recalled_delly_sv_index
        set val(SM), file("${SM}_second.vcf") into delly_to_db


    """
        delly call ${SM}.bam -v ${combined_delly_bcf} -g ${reference_handle_uncompressed} -o ${SM}_second.bcf
        bcftools view -Ov -o ${SM}_second.vcf ${SM}_second.bcf
    """

}

recalled_delly_sv
  .toSortedList()
  .set { recalled_delly_sv_bcf }

recalled_delly_sv_index
  .toSortedList()
  .set { recalled_delly_sv_bcf_index }

process combine_second_deletions {
        
    publishDir params.out + "/variation", mode: 'copy'

    input:
        file recalled_delly_sv_bcf
        file recalled_delly_sv_bcf_index

    output:
        set file("WI.${date}.DELLYsv.raw.vcf.gz"), file("WI.${date}.DELLYsv.raw.vcf.gz.csi") into raw_recalled_wi_dell_sv
        set file("WI.${date}.DELLYsv.germline-filter.vcf.gz"), file("WI.${date}.DELLYsv.germline-filter.vcf.gz.csi") into germline_recalled_wi_dell_sv
        file "WI.${date}.DELLYsv.raw.stats.txt" into delly_bcf_stats

    script:
        """
            bcftools merge -m id -O b -o WI.${date}.DELLYsv.raw.bcf ${recalled_delly_sv_bcf}
            bcftools index -f WI.${date}.DELLYsv.raw.bcf
            bcftools query -l WI.${date}.DELLYsv.raw.bcf | sort > sample_names.txt
            bcftools view --samples-file=sample_names.txt -Oz -o WI.${date}.DELLYsv.raw.vcf.gz WI.${date}.DELLYsv.raw.bcf
            bcftools index -f WI.${date}.DELLYsv.raw.vcf.gz

            delly filter -f germline WI.${date}.DELLYsv.raw.bcf -o WI.${date}.DELLYsv.germline-filter.bcf

            bcftools index -f WI.${date}.DELLYsv.germline-filter.bcf
            bcftools view --samples-file=sample_names.txt -Oz -o WI.${date}.DELLYsv.germline-filter.vcf.gz WI.${date}.DELLYsv.germline-filter.bcf
            bcftools index -f WI.${date}.DELLYsv.germline-filter.vcf.gz

            bcftools stats --verbose WI.${date}.DELLYsv.raw.vcf.gz > WI.${date}.DELLYsv.raw.stats.txt     
        """
}

process delly_snpeff {
    
    cpus params.cores

    publishDir params.out + "/variation", mode: 'copy'

    input:
        set file(dellysv), file(dellysvindex) from germline_recalled_wi_dell_sv
        file("gene.pkl") from gene_pkl_manta

    output:
        set file("WI.${date}.DELLYsv.snpEff.vcf.gz"), file("WI.${date}.DELLYsv.snpEff.vcf.gz.csi") into snpeff_delly_vcf
        file("DELLYsv_snpeff_out.csv") into snpeff_delly_multiqc

    when:
        params.tiddit_discord


    script:
      """
        bcftools view --threads ${task.cpus-1} ${dellysv} | \\
        snpEff eff -csvStats DELLYsv_snpeff_out.csv \\
        -no-downstream \\
        -no-intergenic \\
        -no-upstream \\
        -dataDir ${params.snpeff_path} \\
        -config ${params.snpeff_path}/snpEff.config \\
        ${params.annotation_reference} | \\
        bcftools view -O v | \\
        python `which fix_snpeff_names.py` - | \\
        bcftools view -O z > WI.${date}.DELLYsv.snpEff.vcf.gz

        bcftools index --threads ${task.cpus} -f WI.${date}.DELLYsv.snpEff.vcf.gz
      """
}

/*
    =========
    TIDDIT-sv
    =========
*/

process tiddit_call_sv {
    
    cpus params.cores
    
    tag { SM }

    input:
        set val(SM), file("${SM}.bam"), file("${SM}.bam.bai") from bam_tiddit

    output:
        file "${SM}_tiddit.vcf.gz" into tiddit_vcf
        file "${SM}_tiddit.vcf.gz.csi" into tiddit_index
        file "*.signals.tab" into tiddit_coverage
        set val(SM), file("${SM}_tiddit.vcf") into tiddit_to_db

    when:
        params.tiddit_discord

    """
        python2 ${params.tiddit} \\
        --sv \\
        -o ${SM}_tiddit \\
        -p ${params.tiddit_discord} \\
        -r ${params.tiddit_discord} \\
        --bam ${SM}.bam \\
        --ref ${reference_handle_uncompressed}

        bcftools view ${SM}_tiddit.vcf | \\
        vk geno transfer-filter - | \\
        bcftools view --threads ${task.cpus-1} -O z > ${SM}_tiddit.vcf.gz

        bcftools index --threads ${task.cpus} -f ${SM}_tiddit.vcf.gz
    """

}

tiddit_vcf
    .toSortedList()
    .set { tiddit_sample_vcfs }

tiddit_index
    .toSortedList()
    .set { tiddit_sample_indices }

tiddit_coverage
    .toSortedList()
    .set { tiddit_sample_coverage }


process merge_tiddit_vcf {
    
    publishDir "${params.out}/variation", mode: 'copy'

    input:
        file tiddit_sample_vcfs
        file tiddit_sample_coverage
        file tiddit_sample_indices

    output:
        set file("WI.${date}.TIDDITsv.soft-filter.vcf.gz"), file("WI.${date}.TIDDITsv.soft-filter.vcf.gz.csi") into softfilter_tiddit_vcf
        file("WI.${date}.TIDDITsv.soft-filter.stats.txt") into tiddit_stats

    when:
        params.tiddit_discord

    """
        bcftools merge -m all --threads ${task.cpus-1} -Ov ${tiddit_sample_vcfs} | \\
        bcftools filter --threads ${task.cpus-1} --set-GTs . --exclude 'FORMAT/FT != "PASS"' -O z | \\
        bcftools view -O z \\
                --samples-file=<(bcftools query -l WI.${date}.TIDDITsv.soft-filter_unsorted.vcf.gz | sort) \\
                 WI.${date}.TIDDITsv.soft-filter_unsorted.vcf.gz > WI.${date}.TIDDITsv.soft-filter.vcf.gz

        bcftools index --threads ${task.cpus} -f WI.${date}.TIDDITsv.soft-filter.vcf.gz
        bcftools stats --verbose WI.${date}.TIDDITsv.soft-filter.vcf.gz > WI.${date}.TIDDITsv.soft-filter.stats.txt
    """

}

process tiddit_snpeff {
        
    publishDir "${params.out}/variation", mode: 'copy'

    input:
        set file(tiddit_joint_vcf), file(tiddit_joint_index) from softfilter_tiddit_vcf
        file("gene.pkl") from gene_pkl_tiddit

    output:
        set file("WI.${date}.TIDDITsv.snpEff.vcf.gz"), file("WI.${date}.TIDDITsv.snpEff.vcf.gz.csi") into snpeff_tiddit_vcf
        file("TIDDITsv_snpeff_out.csv") into snpeff_tiddit_multiqc
    
    when:
        params.tiddit_discord

    """
        bcftools view ${tiddit_joint_vcf} | \\
        snpEff eff -csvStats TIDDITsv_snpeff_out.csv \\
        -no-downstream -no-intergenic -no-upstream \\
        -dataDir ${params.snpeff_path} \\
        -config ${params.snpeff_path}/snpEff.config \\
        ${params.annotation_reference} | \\
        bcftools view -O v | \\
        python `which fix_snpeff_names.py` - | \\
        bcftools view -O z > WI.${date}.TIDDITsv.snpEff.vcf.gz

        bcftools index -f WI.${date}.TIDDITsv.snpEff.vcf.gz
    """
}


manta_to_db
    .join(delly_to_db)
    .join(tiddit_to_db)
    .set { variant_db }


process merge_sv_callers {

    input:
        set val(SM), file(mantasv), file(dellysv), file(tidditsv) from variant_db

    output:
        file("${SM}_merged_caller.vcf.gz") into sample_merged_svcaller_vcf
        file("${SM}_merged_caller.vcf.gz.csi") into sample_merged_svcaller_index

    when:
        params.tiddit_discord

    script:
      """
        echo ${SM} > samplename.txt

        svdb --merge --pass_only --no_var --vcf ${dellysv}:delly ${mantasv}:manta ${tidditsv}:tiddit --priority delly,manta,tiddit| \\
        bcftools reheader -s samplename.txt | \\
        awk '\$0 ~ "#" {print} !seen[\$1"\t"\$2]++ {print}' | \\
        bcftools view -Oz -o ${SM}_merged_caller.vcf.gz

        bcftools index -f ${SM}_merged_caller.vcf.gz
      """
}

sample_merged_svcaller_vcf
    .toSortedList()
    .set { merged_sample_sv_vcf }

sample_merged_svcaller_index
    .toSortedList()
    .set { merged_sample_sv_index }


process merge_wi_sv_callers {

    publishDir "${params.out}/variation", mode: 'copy'

    input:
        file(mergedSVvcf) from merged_sample_sv_vcf
        file(mergedSVindex) from merged_sample_sv_index
        file("gene.pkl") from gene_pkl_svdb

    output:
        file "WI.${date}.MERGEDsv.snpEff.vcf.gz" into wi_mergedsv

    when:
        params.tiddit_discord

    """
        bcftools merge -m all --threads ${task.cpus} -O z ${mergedSVvcf} > temp_merged.vcf.gz

        bcftools view -Ov temp_merged.vcf.gz | grep '^#'  > db_merged_temp_sorted.vcf
        bcftools view -Ov temp_merged.vcf.gz | grep -v -E '^X|^MtDNA|^#' | sort -k1,1d -k2,2n >> db_merged_temp_sorted.vcf
        bcftools view -Ov temp_merged.vcf.gz | grep -E '^X' | sort -k1,1d -k2,2n >> db_merged_temp_sorted.vcf
        bcftools view -Ov temp_merged.vcf.gz | grep -E '^MtDNA' | sort -k1,1d -k2,2n >> db_merged_temp_sorted.vcf

        bcftools query -l db_merged_temp_sorted.vcf | sort > sample_names.txt

        bcftools view --samples-file=sample_names.txt -Ov db_merged_temp_sorted.vcf | \\
        snpEff eff -csvStats MERGEDsv_snpeff_out.csv \\
        -no-downstream -no-intergenic -no-upstream \\
        -dataDir ${params.snpeff_path} \\
        -config ${params.snpeff_path}/snpEff.config \\
        ${params.annotation_reference} | \\
        bcftools view -O v | \\
        python `which fix_snpeff_names.py` - | \\
        bcftools view -O z > WI.${date}.MERGEDsv.snpEff.vcf.gz

        bcftools index -f WI.${date}.MERGEDsv.snpEff.vcf.gz
    """
}

process multiqc_report {

    executor 'local'

    publishDir "${params.out}/report", mode: 'copy'

    input:
        file("stat*") from vcf_stats.toSortedList()
        file(samtools_stats) from SM_samtools_stats_set.toSortedList()
        //file(bamtools_stats) from SM_bamtools_stats_set.toSortedList()
        file(duplicates) from duplicates_set.toSortedList()
        file(fastqc) from SM_fastqc_stats_set.toSortedList()
        file("bam*.idxstats") from bam_idxstats_multiqc.toSortedList()
        file("picard*.stats.txt") from SM_picard_stats_set.collect()
        file("snpeff_out.csv") from snpeff_multiqc
        file("DELLYsv_snpeff_out.csv") from snpeff_delly_multiqc
        file("MANTAsv_snpeff_out.csv") from manta_snpeff_multiqc
        file("WI.${date}.DELLYsv.raw.stats.txt") from delly_bcf_stats
        file("WI.${date}.MANTAsv.soft-filter.stats.txt") from bcf_manta_stats
        file("WI.${date}.TIDDITsv.soft-filter.stats.txt") from tiddit_stats
        file("TIDDITsv_snpeff_out.csv") from snpeff_tiddit_multiqc

    output:
        file("multiqc_data/*.json") into multiqc_json_files
        file("multiqc.html")

    """
        multiqc -k json --filename multiqc.html .
    """

}

process comprehensive_report {


    input:
        file("multiqc_data/*.json") from multiqc_json_files

    """
        echo "great"
        exit 0
    """

}

workflow.onComplete {

    summary = """

    Pipeline execution summary
    ---------------------------
    Completed at: ${workflow.complete}
    Duration    : ${workflow.duration}
    Success     : ${workflow.success}
    workDir     : ${workflow.workDir}
    exit status : ${workflow.exitStatus}
    Error report: ${workflow.errorReport ?: '-'}
    Git info: $workflow.repository - $workflow.revision [$workflow.commitId]

    """

    println summary

    def outlog = new File("${params.out}/log.txt")
    outlog.newWriter().withWriter {
        outlog << param_summary
        outlog << summary
    }

    // mail summary
    if (params.email) {
        ['mail', '-s', 'wi-nf', params.email].execute() << summary
    }


}