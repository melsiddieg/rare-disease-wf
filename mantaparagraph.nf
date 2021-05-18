nextflow.enable.dsl=2

include { split_by_size } from "./split"


process manta {
    errorStrategy 'terminate' // TODO: change after debugging is done
    stageInMode "copy"

    container = 'docker://brentp/manta-paragraph:v0.1.8'
    publishDir "results-rare-disease/manta-vcfs/", mode: 'copy'
    shell = ['/bin/bash', '-euo', 'pipefail']

    input:
        tuple(val(sample_name), path(bam), path(index))
        path(fasta)
        path(fai)

    output:
        tuple(file("${sample_name}.diploidSV.vcf.gz"), file("${sample_name}.meandepth.txt"))

    script:
    """
# limit to larger chroms ( > 10MB)
awk '\$2 > 10000000 || \$1 ~/(M|MT)\$/ { print \$1"\t0\t"\$2 }' $fai | bgzip -c > cr.bed.gz
tiwih meandepth --scale-by-read-length $bam > ${sample_name}.meandepth.txt

tabix cr.bed.gz
configManta.py --bam ${bam} --referenceFasta $fasta --runDir . --callRegions cr.bed.gz
python2 ./runWorkflow.py -j ${task.cpus}

convertInversion.py \$(which samtools) $fasta results/variants/diploidSV.vcf.gz \
    | bcftools view -O z -o ${sample_name}.diploidSV.vcf.gz

mv results/variants/candidateSV.vcf.gz ${sample_name}.candidateSV.vcf.gz
mv results/variants/candidateSmallIndels.vcf.gz ${sample_name}.candidateSmallIndels.vcf.gz
rm -rf results/
    """
}

process svimmer {
    container = 'docker://brentp/manta-paragraph:v0.1.8'
    publishDir "results-rare-disease/manta-merged/", mode: 'copy'
    shell = ['/bin/bash', '-euo', 'pipefail']

    input:
        val(sample_vcfs)
        path(fai)
    output: tuple(file("${output_file}"), file("${output_file}.tbi"))

    script:
    output_file = "svimmer.merged.vcf.gz"
    file("$workDir/vcfs.list").withWriter { fh ->
            sample_vcfs.each { vcf ->
                fh.write(vcf.toString()); fh.write("\n")
            }
    }
    """
    cat $workDir/vcfs.list | xargs -I{} -P ${task.cpus} bcftools index -f --threads 2 {}
    chroms=\$(awk '\$2 > 10000000 { printf("%s ", \$1) }' $fai) 
    # NOTE: removing BNDs
    svimmer --max_distance 100 --max_size_difference 60 $workDir/vcfs.list \$chroms \
        | tiwih setsvalt --drop-bnds /dev/stdin  -o $output_file
    tabix $output_file
    """
}

process paragraph {
  errorStrategy 'terminate' // TODO: change after debugging is done
  shell = ['/bin/bash', '-euo', 'pipefail']
  container = 'docker://brentp/manta-paragraph:v0.1.8'

  publishDir "results-rare-disease/svs-paragraph/", mode: 'copy'

  input:
     tuple(path(site_vcf), path(site_vcf_index))
     tuple(val(sample), path(bam), path(index))
     path(fasta)
     path(fai)

  output: path("*.paragraph.vcf.gz")

  script:
  """
samplename=$sample
dp=\$(tiwih meandepth $bam)
echo "id\tpath\tdepth\tread length" > sample.manifest
echo "$sample\t$bam\t\$dp\t150" >> sample.manifest
M=\$((dp * 5))
cat sample.manifest

multigrmpy.py -i $site_vcf \
    -m sample.manifest \
    -r $fasta \
    -o t \
    -t ${task.cpus} \
    -M \$M

mv t/genotypes.vcf.gz \${samplename}.paragraph.vcf.gz

  """

}

workflow {

    fasta = "/hpc/cog_bioinf/GENOMES.old/NF-IAP-resources//GRCh37/Sequence/genome.fa"
    samples = [
        ["150424",
        "/hpc/cog_bioinf/ubec/useq/processed_data/external/REN5302/REN5302_5/BAMS/150424_dedup.bam",
        "/hpc/cog_bioinf/ubec/useq/processed_data/external/REN5302/REN5302_5/BAMS/150424_dedup.bai"],
        ["150423",
        "/hpc/cog_bioinf/ubec/useq/processed_data/external/REN5302/REN5302_5/BAMS/150423_dedup.bam",
        "/hpc/cog_bioinf/ubec/useq/processed_data/external/REN5302/REN5302_5/BAMS/150423_dedup.bai"],
        ["150426",
        "/hpc/cog_bioinf/ubec/useq/processed_data/external/REN5302/REN5302_5/BAMS/150426_dedup.bam",
        "/hpc/cog_bioinf/ubec/useq/processed_data/external/REN5302/REN5302_5/BAMS/150426_dedup.bai"]
    ]
    input = channel.fromList(samples)


    manta_results = manta(input, fasta, fasta + ".fai")

    mr = manta_results | map { it -> it[0] }  | collect
    mds = manta_results | map { it -> it[1] }  | collect

    sv_merged = svimmer(mr, fasta + ".fai")

    paragraph(sv_merged, input, fasta, fasta + ".fai")

}