#!/usr/bin/env perl
use strict;
use warnings;
use File::Copy;
use Path::Class;

BEGIN {
    use Test::Most tests => 5;
    use VRPipeTest (required_env => 'VRPIPE_TEST_PIPELINES');
    use TestPipelines;
}

my $stats_output_dir = get_output_dir('bam_qc_graphs_and_stats');
my $target_output_dir = get_output_dir('bam_qc_graphs_and_stats_targeted');

ok my $stats_pipeline = VRPipe::Pipeline->get(name => 'bam_qc_graphs_and_stats'), 'able to get the bam_qc_graphs_and_stats pipeline';

my @s_names;
foreach my $stepmember ($stats_pipeline->steps) {
    push(@s_names, $stepmember->step->name);
}
my @expected_step_names = qw(fasta_gc_stats
                             bamcheck
                             plot_bamcheck
                             bamcheck_stats_output);

is_deeply \@s_names, \@expected_step_names, 'the pipeline has the correct steps';

my $ref_fa_source = file(qw(t data human_g1k_v37.chr20.fa));
my $ref_dir = dir($stats_output_dir, 'ref');
$stats_pipeline->make_path($ref_dir);
my $ref_fa = file($ref_dir, 'human_g1k_v37.chr20.fa')->stringify;
copy($ref_fa_source, $ref_fa);

my $fa_index_source = file(qw(t data human_g1k_v37.chr20.fa.fai));
my $fa_index = file($ref_dir, 'human_g1k_v37.chr20.fa.fai')->stringify;
copy($fa_index_source, $fa_index);

my $bc_options = "-q 20";

my $ds = VRPipe::DataSource->get(type => 'fofn',
                                 method => 'all',
                                 source => file(qw(t data hs_chr20.qc.bam.fofn))->absolute);

# setup 2 pipelines, 1 wgs, 1 exome
VRPipe::PipelineSetup->get(name => 'graphs_and_stats whole genome',
                           datasource => $ds,
                           output_root => $stats_output_dir,
                           pipeline => $stats_pipeline,
                           options => {reference_fasta => $ref_fa,
                                       bamcheck_options => $bc_options});

VRPipe::PipelineSetup->get(name => 'graphs_and_stats exome',
                           datasource => $ds,
                           output_root => $target_output_dir,
                           pipeline => $stats_pipeline,
                           options => {reference_fasta => $ref_fa,
                                       bamcheck_options => $bc_options,
                                       exome_targets_file => file(qw(t data hs_chr20.invervals.tab))->absolute->stringify});

my (@output_files, @target_files);
my @other_files = (file($ref_dir, 'human_g1k_v37.chr20.fa.gc_stats'),
                   file($ref_dir, 'human_g1k_v37.chr20.fa.gc_stats.targeted-9cc6c71308612098ffcd32445361f4c6'));
my $element_id = 0;
my $rg = "ERR012999";
foreach my $in ('hs_chr20.a', 'hs_chr20.b', 'hs_chr20.c', 'hs_chr20.d') {
    $element_id++;
    my @output_subdirs = output_subdirs($element_id, 1);
    my @target_subdirs = output_subdirs($element_id, 2);
    foreach my $aref ([\@output_files, \@output_subdirs], [\@target_files, \@target_subdirs]) {
        push(@{$aref->[0]}, file(@{$aref->[1]}, '2_bamcheck', "$in.bam.bamcheck"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-acgt-cycles.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-coverage.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-gc-content.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-gc-depth.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-indel-cycles.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-indel-dist.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-insert-size.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-mism-per-cycle.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-quals2.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-quals3.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-quals-hm.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '3_plot_bamcheck', "$rg-quals.png"));
        push(@{$aref->[0]}, file(@{$aref->[1]}, '4_bamcheck_stats_output', "$in.bam.detailed_stats"));
    }
}

ok handle_pipeline(@other_files, @output_files, @target_files), 'pipeline ran and created all expected output files';

# check that the results for wgs vs exome are actually different
my $wgs_bamcheck_meta = VRPipe::File->get(path => $output_files[0])->metadata;
my $wes_bamcheck_meta = VRPipe::File->get(path => $target_files[0])->metadata;
is_deeply [$wgs_bamcheck_meta->{reads}, $wes_bamcheck_meta->{reads}], [912, 862], 'bamcheck results are as expected and different comparing with and without use of targets file';

# they should also have coverage stats
is_deeply [$wes_bamcheck_meta->{bases_of_1X_coverage},
           $wes_bamcheck_meta->{bases_of_2X_coverage},
           $wes_bamcheck_meta->{bases_of_5X_coverage},
           $wes_bamcheck_meta->{bases_of_10X_coverage},
           $wes_bamcheck_meta->{bases_of_20X_coverage},
           $wes_bamcheck_meta->{bases_of_50X_coverage},
           $wes_bamcheck_meta->{bases_of_100X_coverage},
           $wes_bamcheck_meta->{mean_coverage}], [36019, 8126, 98, 0, 0, 0, 0, 1.29], 'bamcheck file also has coverage metadata';

done_testing;

finish;