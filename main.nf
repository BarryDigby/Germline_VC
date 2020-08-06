#!/usr/bin/env nextflow

/*
================================================================================
                           Germline Variant Calling
================================================================================
Galway Genomics
July 2019
--------------------------------------------------------------------------------
@Homepage
https://github.com/BarryDigby/Germline_VC
--------------------------------------------------------------------------------
@Usage
nextflow -bg -q run BarryDigby/Germline_VC -profile standard, singularity \
--refDir /path/to/genome/files --outDir /path/to/publish
--------------------------------------------------------------------------------
*/

/*
 Reference Files
*/

params.fasta = Channel.fromPath("$params.refDir/*fasta").getVal()
params.fai = Channel.fromPath("$params.refDir/*fasta.fai").getVal()
params.dict = Channel.fromPath("$params.refDir/*dict").getVal()

params.amb = Channel.fromPath("$params.refDir/*fasta.amb").getVal()
params.ann = Channel.fromPath("$params.refDir/*fasta.ann").getVal()
params.bwt = Channel.fromPath("$params.refDir/*fasta.bwt").getVal()
params.pac = Channel.fromPath("$params.refDir/*fasta.pac").getVal()
params.sa = Channel.fromPath("$params.refDir/*fasta.sa").getVal()

/*
 Exome Intervals, files
*/

params.intlist = Channel.fromPath("$params.refDir/exome/*.bed.interval_list").getVal()
params.bed = Channel.fromPath("$params.refDir/exome/*.bed").getVal()
params.bedgz = Channel.fromPath("$params.refDir/exome/*.bed.gz").getVal()
params.bedgztbi = Channel.fromPath("$params.refDir/exome/*.bed.gz.tbi").getVal()

/*
 dbSNP, known Indels
*/

params.dbsnp = Channel.fromPath("$params.refDir/dbsnp*.gz").getVal()
params.dbsnptbi = Channel.fromPath("$params.refDir/dbsnp*.tbi").getVal()
params.mills = Channel.fromPath("$params.refDir/Mills_KG*.gz").getVal()
params.millstbi = Channel.fromPath("$params.refDir/Mills_KG*.gz.tbi").getVal()

/*
 Annotation cache, database versions
*/

params.vep_cache = "/data/VEP/GRCh37"
params.vep_version = "99"
params.cadd_wg_snvs = Channel.fromPath("/data/VEP/GRCh37/Plugin_files/whole_genome_SNVs.tsv.gz").getVal()
params.cadd_wg_snvs_tbi = Channel.fromPath("/data/VEP/GRCh37/Plugin_files/whole_genome_SNVs.tsv.gz.tbi").getVal()
params.cadd_indels = Channel.fromPath("/data/VEP/GRCh37/Plugin_files/InDels.tsv.gz").getVal()
params.cadd_indels_tbi = Channel.fromPath("/data/VEP/GRCh37/Plugin_files/InDels.tsv.gz.tbi").getVal()
params.lof = Channel.fromPath("/data/VEP/VEP_plugins/LoFtool_scores.txt").getVal()

params.snpeff_cache = "/data/snpEff"
params.snpeff_db = "GRCh37.75"

// Not sure where to use these files, omit for now 
//params.omni = Channel.fromPath("$params.refDir/KG_omni*.gz").getVal()
//params.otbi = Channel.fromPath("$params.refDir/KG_omni*.gz.tbi").getVal()
//params.kgp1 = Channel.fromPath("$params.refDir/KG_phase1*.gz").getVal()
//params.ktbi = Channel.fromPath("$params.refDir/KG_phase1*.gz.tbi").getVal()
//params.hpmp = Channel.fromPath("$params.refDir/hapmap*.gz").getVal()
//params.htbi = Channel.fromPath("$params.refDir/hapmap*.gz.tbi").getVal()

//params.gps = Channel.fromPath("$params.refDir/exome/af-only-gnomad.*.vcf.gz").getVal()
//params.gpstbi = Channel.fromPath("$params.refDir/exome/af-only-gnomad.*.vcf.gz.tbi").getVal()

/*
 FASTQ reads
*/

params.reads = "/data/bdigby/WES/reads/*trim_R{1,2}.fastq.gz"
Channel
        .fromFilePairs( params.reads )
        .set{ reads_ch }

/*
 Initialise outDir
*/

params.outDir = ""

/*
================================================================================
                                  PREPROCESSING
================================================================================
*/


process MapReads{
        
	publishDir path: "$params.outDir/analysis/bwa", mode: "copy"
	
        input:
        tuple val(base), file(reads) from reads_ch
        tuple file(fasta), file(fai) from Channel.value([params.fasta, params.fai])
        tuple file(amb), file(ann), file(bwt), file(pac), file(sa) from Channel.value([params.amb, params.ann, params.bwt, params.pac, params.sa])
        
        output:
        tuple val(base), file("${base}.bam") into bamMapped
	tuple val(base), file("${base}.bam") into bamMappedBamQC

        script:
        readGroup = "@RG\\tID:HT52VDMXX\\tPU:HT52VDMXX:1\\tSM:METIN\\tLB:METIN\\tPL:illumina"
        """
        bwa mem -K 100000000 -R \"${readGroup}\" -t 8 -M $fasta $reads | \
        samtools sort --threads 8 - > ${base}.bam
        """
}


process MarkDuplicates{

	publishDir path: "$params.outDir/analysis/mark_dups", mode: "copy"

	input:
	tuple val(base), file(bam) from bamMapped

	output:
	tuple val(base), file("${base}.md.bam"), file("${base}.md.bam.bai") into bam_duplicates_marked
	tuple val(base), file("${base}.bam.metrics") into into duplicates_marked_report
	
	script:
	"""
	gatk --java-options -Xmx8g \
        MarkDuplicates \
        --MAX_RECORDS_IN_RAM 50000 \
        --INPUT $bam \
        --METRICS_FILE ${base}.bam.metrics \
        --TMP_DIR . \
        --ASSUME_SORT_ORDER coordinate \
        --CREATE_INDEX true \
        --OUTPUT ${base}.md.bam
    
        mv ${base}.md.bai ${base}.md.bam.bai
	"""
}


duplicates_marked_report = duplicates_marked_report.dump(tag:'MD Report')


process BQSR{

	publishDir path: "$params.outDir/analysis/bqsr", mode: "copy"

	input:
	tuple val(base), file(bam), file(bai) from bam_duplicates_marked
	tuple file(fasta), file(fai), file(dict), file(intlist) from Channel.value([params.fasta, params.fai, params.dict, params.intlist])
	tuple file(dbsnp), file(dbsnptbi) from Channel.value([params.dbsnp, params.dbsnptbi])
	tuple file(mills), file(millstbi) from Channel.value([params.mills, params.millstbi])

	output:
	tuple val(base), file("${base}.recal.bam"), file("${base}.recal.bam.bai") into BQSR_bams
	tuple val(base), file("${base}.recal.bam") into bam_recalibrated_qc
	tuple val(base), file("${base}.recal.stats.out") into samtoolsStatsReport

	script:
	"""
	gatk --java-options -Xmx8g \
	BaseRecalibrator \
	-I $bam \
	-O ${base}.recal.table \
	--tmp-dir . \
	-R $fasta \
	-L $intlist \
	--known-sites $dbsnp \
	--known-sites $mills 

	gatk --java-options -Xmx8g \
	ApplyBQSR \
	-I $bam \
	-O ${base}.recal.bam \
	-R $fasta \
	-L $intlist \
	--bqsr-recal-file ${base}.recal.table

	samtools index ${base}.recal.bam ${base}.recal.bam.bai
	samtools stats ${base}.recal.bam > ${base}.recal.stats.out
	"""
}

samtoolsStatsReport = samtoolsStatsReport.dump(tag:'SAMTools')


/*
================================================================================
                            GERMLINE VARIANT CALLING
================================================================================
*/


process HaplotypeCaller {

	publishDir path: "$params.outDir/analysis/haplotypecaller", mode: "copy"
	
	input:
	tuple val(base), file(bam), file(bai) from BQSR_bams
	tuple file(fasta), file(fai), file(dict), file(intlist) from Channel.value([params.fasta, params.fai, params.dict, params.intlist])
	tuple file(dbsnp), file(dbsnptbi) from Channel.value([params.dbsnp, params.dbsnptbi])
	
	output:
	tuple val(base), file("${base}.g.vcf") into gvcfHaplotypeCaller
	
	script:
	"""
	gatk --java-options -Xmx8g \
        HaplotypeCaller \
        -R ${fasta} \
        -I ${bam} \
        -L $intlist \
        --D $dbsnp \
        -O ${base}.g.vcf \
        -ERC GVCF
	"""
}


process GenotypeGVCFs {

	publishDir path: "$params.outDir/analysis/genotypeGVCF", mode: "copy"
	
	input:
	tuple val(base), file(gvcf) from gvcfHaplotypeCaller
	tuple file(fasta), file(fai), file(dict), file(intlist) from Channel.value([params.fasta, params.fai, params.dict, params.intlist])
	tuple file(dbsnp), file(dbsnptbi) from Channel.value([params.dbsnp, params.dbsnptbi])
	
	output:
	tuple val(base), file("${base}.vcf") into vcfGenotypeGVCFs
	
	script:
	"""
	gatk --java-options -Xmx8g \
	IndexFeatureFile \
        -I ${gvcf}
	
	gatk --java-options -Xmx8g \
        GenotypeGVCFs \
        -R ${fasta} \
        -L $intlist \
        --D $dbsnp \
        -V ${gvcf} \
        -O ${base}.vcf
	"""
}


(filter_snps, filter_indels, vcfVEP, vcfsnpEff, bcfstats, vcfstats) = vcfGenotypeGVCFs.into(6)


process Filter_SNPs {
	
	publishDir path: "$params.outDir/analysis/SNPs", mode: "copy"
	
	input:
	tuple val(base), file(vcf) from filter_snps
	
	output:
	tuple val(base), file('*.snps.vcf.gz') into snps_filtered
	
	script:
	"""
	gatk SelectVariants \
    	-V $vcf \
    	-select-type SNP \
    	-O ${base}.snps.vcf.gz
	"""
}


process Filter_Indels {

	publishDir path: "$params.outDir/analysis/Indels", mode: "copy"
	
	input:
	tuple val(base), file(vcf) from filter_indels
	
	output:
	tuple val(base), file('*.indels.vcf.gz') into indels_filtered
	
	script:
	"""
	gatk SelectVariants \
    	-V $vcf \
    	-select-type INDEL \
    	-O ${base}.indels.vcf.gz
	"""
}


/*
================================================================================
                                 ANNOTATION
			  Run snpEff | compress output
		       Run VEP | Run VEP on snpEff VCF
			   compress both VEP outputs
================================================================================
*/


process snpEff {

	publishDir path: "$params.outDir/analysis/snpEff", mode: "copy"
	
	input:
	tuple val(base), file(vcf) from vcfsnpEff
	val(cache) from params.snpeff_cache
	val(database) from params.snpeff_db
	
	output:
	tuple val(base), file("${base}_snpEff.genes.txt"), file("${base}_snpEff.html"), file("${base}_snpEff.csv") into snpeffReport
        tuple val(base), file("${base}_snpEff.ann.vcf") into snpeffVCF

	script:
	cache = "-dataDir ${cache}"
	"""
	snpEff -Xmx8g \
        ${database} \
        -csvStats ${base}_snpEff.csv \
        -nodownload \
        ${cache} \
        -canon \
        -v \
        ${vcf} \
        > ${base}_snpEff.ann.vcf
	
    	mv snpEff_summary.html ${base}_snpEff.html
	"""
}


snpeffReport = snpeffReport.dump(tag:'snpEff report')


process CompressVCFsnpEff {

    publishDir path: "$params.outDir/analysis/snpEff", mode: "copy"

    input:
    tuple val(base), file(vcf) from snpeffVCF

    output:
    tuple val(base), file("*.vcf.gz"), file("*.vcf.gz.tbi") into compressVCFsnpEffOut

    script:
    """
    bgzip < ${vcf} > ${vcf}.gz
    tabix ${vcf}.gz
    """
}


process VEP {

    	publishDir path: "$params.outDir/analysis/VEP", mode: "copy"

    	input:
        tuple val(base), file(vcf) from vcfVEP
        val(dataDir) from params.vep_cache
        val(vepversion) from params.vep_version
	file(fasta) from params.fasta
	tuple file(cadd_snv), file(cadd_snv_tbi) from Channel.value([params.cadd_wg_snvs, params.cadd_wg_snvs_tbi])
	tuple file(cadd_indels), file(cadd_indels_tbi) from Channel.value([params.cadd_indels, params.cadd_indels_tbi])
	file(lof) from params.lof
	
    	output:
        tuple val(base), file("${base}_VEP.ann.vcf") into vepVCF
        file("${base}_VEP.summary.html") into vepReport


    	script:
	CADD = "--plugin CADD,whole_genome_SNVs.tsv.gz,InDels.tsv.gz"
	LOF = "--plugin LoFtool,LoFtool_scores.txt"
	genesplicer = "--plugin GeneSplicer,/opt/conda/envs/Germline_VC/bin/genesplicer,/opt/conda/envs/Germline_VC/share/genesplicer-1.0-1/human,context=200,tmpdir=\$PWD/${base}"
    	"""
    	vep \
    	-i ${vcf} \
    	-o ${base}_VEP.ann.vcf \
    	--assembly GRCh37 \
    	--species homo_sapiens \
	${CADD} \
	${LOF} \
	${genesplicer} \
	--offline \
    	--cache \
	--fasta $fasta \
    	--cache_version ${vepversion} \
    	--dir_cache ${dataDir} \
    	--everything \
    	--filter_common \
    	--fork 4 \
    	--format vcf \
    	--per_gene \
    	--stats_file ${base}_VEP.summary.html \
    	--total_length \
    	--vcf
	
	rm -rf ${base}
    	"""
}


vepReport = vepReport.dump(tag:'VEP')


process VEPsnpEff {

    	publishDir path: "$params.outDir/analysis/snpEff", mode: "copy"

    	input:
        tuple val(base), file(vcf) from compressVCFsnpEffOut
        val(dataDir) from params.vep_cache
        val(vepversion) from params.vep_version
	file(fasta) from params.fasta
	tuple file(cadd_snv), file(cadd_snv_tbi) from Channel.value([params.cadd_wg_snvs, params.cadd_wg_snvs_tbi])
	tuple file(cadd_indels), file(cadd_indels_tbi) from Channel.value([params.cadd_indels, params.cadd_indels_tbi])
	file(lof) from params.lof
	
    	output:
        tuple val(base), file("${base}_VEP.ann.vcf") into vepVCFmerge
        file("${base}_VEP.summary.html") into vepReportMerge


    	script:
	CADD = "--plugin CADD,whole_genome_SNVs.tsv.gz,InDels.tsv.gz"
	LOF = "--plugin LoFtool,LoFtool_scores.txt"
	genesplicer = "--plugin GeneSplicer,/opt/conda/envs/Germline_VC/bin/genesplicer,/opt/conda/envs/Germline_VC/share/genesplicer-1.0-1/human,context=200,tmpdir=\$PWD/${base}"
    	"""
    	vep \
    	-i ${vcf} \
    	-o ${base}_VEP.ann.vcf \
    	--assembly GRCh37 \
    	--species homo_sapiens \
	${CADD} \
	${LOF} \
	${genesplicer} \
	--offline \
    	--cache \
	--fasta $fasta \
    	--cache_version ${vepversion} \
    	--dir_cache ${dataDir} \
    	--everything \
    	--filter_common \
    	--fork 4 \
    	--format vcf \
    	--per_gene \
    	--stats_file ${base}_VEP.summary.html \
    	--total_length \
    	--vcf
	
	rm -rf ${base}
    	"""
}


vepReportMerge = vepReportMerge.dump(tag:'VEP')


vcfCompressVCFvep = vepVCF.mix(vepVCFmerge)


process CompressVCFvep {

    publishDir path: "$params.outDir/analysis/combined_annot", mode: "copy"

    input:
    tuple val(base), file(vcf) from vcfCompressVCFvep

    output:
    tuple val(base), file("*.vcf.gz"), file("*.vcf.gz.tbi") into compressVCFOutVEP

    script:
    """
    bgzip < ${vcf} > ${vcf}.gz
    tabix ${vcf}.gz
    """
}



/*
================================================================================
				Quality Control
================================================================================
*/

process BamQC {

    publishDir path: "$params.outDir/analysis/bamQC", mode: "copy"

    input:
    tuple val(base), file(bam) from bam_recalibrated_qc
    file(targetBED) from params.bed

    output:
     file("${bam.baseName}") into bamQCReport

    script:
    use_bed = "-gff ${targetBED}"
    """
    qualimap --java-mem-size=8G \
        bamqc \
        -bam ${bam} \
        --paint-chromosome-limits \
        --genome-gc-distr HUMAN \
        $use_bed \
        -nt 8 \
        -skip-duplicated \
        --skip-dup-mode 0 \
        -outdir ${bam.baseName} \
        -outformat HTML
    """
}

bamQCReport = bamQCReport.dump(tag:'BamQC')


process BcftoolsStats {

    publishDir path: "$params.outDir/analysis/quality", mode: "copy"

    input:
    tuple val(base), file(vcf) from bcfstats

    output:
    file ("*.bcf.tools.stats.out") into bcftoolsReport

    script:
    """
    bcftools stats ${vcf} > ${base}.bcf.tools.stats.out
    """
}


bcftoolsReport = bcftoolsReport.dump(tag:'BCFTools')


process Vcftools {

    publishDir path: "$params.outDir/analysis/quality", mode: "copy"

    input:
    tuple val(base), file(vcf) from vcfstats

    output:
    file ("${base}.*") into vcftoolsReport

    script:
    """
    vcftools \
    --gzvcf ${vcf} \
    --TsTv-by-count \
    --out ${base}_count
    
    vcftools \
    --gzvcf ${vcf} \
    --TsTv-by-qual \
    --out ${base}_qual
    
    vcftools \
    --gzvcf ${vcf} \
    --FILTER-summary \
    --out ${base}_summary
    """
}


vcftoolsReport = vcftoolsReport.dump(tag:'VCFTools')



process MultiQC {

    publishDir path: "$params.outDir/analysis/MultiQC", mode: "copy"

    input:
        file ('bamQC/*') from bamQCReport.collect().ifEmpty([])
        file ('BCFTools/*') from bcftoolsReport.collect().ifEmpty([])
        file ('MarkDuplicates/*') from duplicates_marked_report.collect().ifEmpty([])
        file ('DuplicatesMarked/*.recal.table') from baseRecalibratorReport.collect().ifEmpty([])
        file ('SamToolsStats/*') from samtoolsStatsReport.collect().ifEmpty([])
        file ('snpEff/*') from snpeffReport.collect().ifEmpty([])
        file ('VCFTools/*') from vcftoolsReport.collect().ifEmpty([])

    output:
    file ("*multiqc_report.html") into ch_multiqc_report
    file ("*_data")
    file ("multiqc_plots")

    script:
    rtitle = "--title Galway Genomics"
    rfilename = "--filename Galway_Genomics_multiqc_report"
    """
    multiqc -f ${rtitle} ${rfilename}  .
    """
}
