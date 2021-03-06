#!/usr/bin/env perl
use strict;
use warnings;
use File::Copy;
use Path::Class;

BEGIN {
    use Test::Most tests => 3;
    use VRPipeTest (required_env => [qw(VRPIPE_TEST_PIPELINES GATK)]);
    use TestPipelines;
}

ok my $vqsr_pipeline = VRPipe::Pipeline->create(name => 'vqsr_for_snps'), 'able to get the vqsr_for_snps pipeline';

my $vqsr_dir = get_output_dir('vqsr_filter_test');

my $original_ref_fa = VRPipe::File->create(path => file(qw(t data human_g1k_v37.chr11.chr20.fa.gz))->absolute);
my $ref_fa = file($vqsr_dir, 'human_g1k_v37.chr11.chr20.fa')->absolute->stringify;
my $new_ref_fa = VRPipe::File->create(path => $ref_fa);
my $oh         = $original_ref_fa->openr;
my $nh         = $new_ref_fa->openw;
while (<$oh>) {
    print $nh $_;
}
close($oh);
close($nh);

# copy input vcfs to the output dir, since we will create .tbi files and don't
# want them in the t/data directory
my $orig_fofn_file = VRPipe::File->create(path => file(qw(t data vqsr_datasource.fofn))->absolute);
my $fofn_file = VRPipe::File->create(path => file($vqsr_dir, 'vqsr_datasource.fofn'));
my $ifh = $orig_fofn_file->openr;
my $ofh = $fofn_file->openw;
print $ofh scalar <$ifh>;
while (<$ifh>) {
    chomp;
    my ($source_path, @meta) = split(/\t/, $_);
    my $source = file($source_path);
    my $dest = file($vqsr_dir, $source->basename);
    copy($source, $dest);
    print $ofh join("\t", $dest, @meta);
    print $ofh "\n";
}
$orig_fofn_file->close;
$fofn_file->close;

my $recal_opts = "--percentBadVariants 0.07 --maxGaussians 1 --minNumBadVariants 10";
$recal_opts .= " -resource:dbsnp,known=true,training=true,truth=false,prior=8.0 " . file(qw(t data dbsnp_132.b37.chr20_reduced.vcf.gz))->absolute->stringify;
$recal_opts .= " -resource:omni,known=false,training=true,truth=false,prior=12.0 " . file(qw(t data 1000G_omni2.5.b37.sites.chr20_reduced.vcf.gz))->absolute->stringify;
$recal_opts .= " -resource:hapmap,known=false,training=true,truth=true,prior=15.0 " . file(qw(t data hapmap_3.3.b37.sites.chr20_reduced.vcf.gz))->absolute->stringify;
$recal_opts .= ' -an QD -an HaplotypeScore';

VRPipe::PipelineSetup->create(
    name       => 'vqsr snps test',
    datasource => VRPipe::DataSource->create(
        type    => 'fofn_with_metadata',
        method  => 'grouped_by_metadata',
        source  => $fofn_file->path,
        options => { metadata_keys => 'analysis_group' },
    ),
    output_root => $vqsr_dir,
    pipeline    => $vqsr_pipeline,
    options     => {
        reference_fasta                      => $ref_fa,
        snp_recalibration_options            => $recal_opts,
        apply_recalibration_options_for_snps => '--ts_filter_level 99.0',
        cleanup                              => 0,
    }
);

my @output_files;
my @output_subdirs = output_subdirs(1, 1);
foreach my $file (qw(recal recal.tranches recal.tranches.pdf recal.r recal.r.pdf)) {
    push(@output_files, file(@output_subdirs, '2_gatk_variant_recalibration_for_snps', 'SNP.' . $file));
}
my $idx = 0;
foreach my $chr (qw(11 20)) {
    push(@output_files, file(@output_subdirs, '3_gatk_apply_recalibration_for_snps', "${chr}.recal_$idx.vcf.gz"));
    push(@output_files, file(@output_subdirs, '3_gatk_apply_recalibration_for_snps', "${chr}.recal_$idx.vcf.gz.tbi"));
    $idx++;
}
ok handle_pipeline(@output_files), 'vqsr_for_snps pipeline ran okay and created all expected output files';

is_deeply [VRPipe::StepState->get(pipelinesetup => 1, stepmember => 2, dataelement => 1)->cmd_summary->summary, VRPipe::StepState->get(pipelinesetup => 1, stepmember => 3, dataelement => 1)->cmd_summary->summary], ['java $jvm_args -jar GenomeAnalysisTK.jar -T VariantRecalibrator -R $reference_fasta -I $vcf_file(s) -recalFile SNP.recal -tranchesFile SNP.recal.tranches -rscriptFile SNP.recal.r -mode SNP ' . $recal_opts, 'java $jvm_args -jar GenomeAnalysisTK.jar -T ApplyRecalibration -R $reference_fasta --input $vcf_file -recalFile SNP.recal -tranchesFile SNP.recal.tranches -o $recalibrated_vcf_file -mode SNP --ts_filter_level 99.0'], 'cmd summaries for the major steps were as expected';

finish;
