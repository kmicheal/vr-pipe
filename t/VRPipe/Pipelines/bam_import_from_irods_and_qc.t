#!/usr/bin/env perl
use strict;
use warnings;
use Path::Class;
use File::Copy;

BEGIN {
    use Test::Most tests => 14;
    # this test is Sanger-specific, only the author needs to run it
    use VRPipeTest (
        required_env => [qw(VRPIPE_TEST_PIPELINES)],
        required_exe => [qw(iget iquest)]
    );
    use TestPipelines;
    
    use_ok('VRPipe::Schema');
}

ok my $schema = VRPipe::Schema->create('VRTrack'), 'could create a VRTrack schema in the graph db';
my $output_dir = get_output_dir('bam_import_from_irods_and_qc');
my $irods_dir = dir($output_dir, 'irods_import')->stringify;

# define datasource and test it stores stuff under the vrtrack schema
ok my $ds = VRPipe::DataSource->create(
    type    => 'irods',
    method  => 'all_with_warehouse_metadata',
    source  => 'uk10k',                      # my personal copy identical to what you'd get using seq, except that they're MT-only
    options => {
        file_query     => q[study_id = 2547 and type = bam and target = 1 and manual_qc like "%"],
        local_root_dir => $irods_dir
    }
  ),
  'could create an irods datasource';

my $results = 0;
foreach my $element (@{ get_elements($ds) }) {
    $results++;
}
is $results, 4, 'got correct number of bams from irods datasource';

my $in_db = 0;
my $vr_file;
my $irods_test_data_dir = '/uk10k/home/sb10#Sanger1/vrpipe_irods_test_data';
foreach my $basename ('9417_4#1.MT.bam', '9417_4#2.MT.bam', '9417_4#3.MT.bam', '9417_4#4.MT.bam') {
    $vr_file = $schema->get('File', { path => "$irods_test_data_dir/$basename" });
    $in_db++ if $vr_file;
}
is $in_db, 4, 'the bams are in the graph database under the VRTrack schema';

my %related = map { $_->label() => $_ } $vr_file->related(incoming => { max_depth => 10 });
my @expected_realted = ('/lustre/scratch109/srpipe/references/Mus_musculus/GRCm38/all/bwa/Mus_musculus.GRCm38.68.dna.toplevel.fa', '9417_4#4.MT', 6784054, 'MEK_res_4', 10090, 2547, 'all_studies');
is_deeply [$related{Alignment}->reference(), $related{Lane}->unique(), $related{Library}->id(), $related{Sample}->name(), $related{Taxon}->id(), $related{Study}->id(), $related{Group}->name(), scalar(keys %related)], [@expected_realted, 7], 'the related hierarchy of a bam is correct in the graph database';

# setup pipeline
ok my $import_qc_pipeline = VRPipe::Pipeline->create(name => 'bam_import_from_irods_and_qc'), 'able to get the bam_import_from_irods_and_qc pipeline';
my @s_names;
foreach my $stepmember ($import_qc_pipeline->step_members) {
    push(@s_names, $stepmember->step->name);
}
is_deeply \@s_names, [qw(irods_get_files_by_basename samtools_fasta_gc_stats samtools_bam_stats plot_bamstats)], 'the pipeline has the correct steps';

my $ref_fa_source = file(qw(t data GRCm38.MT.ref.fa));
my $ref_dir = dir($output_dir, 'ref');
$import_qc_pipeline->make_path($ref_dir);
my $ref_fa = file($ref_dir, 'ref.fa')->stringify;
copy($ref_fa_source, $ref_fa);

VRPipe::PipelineSetup->create(
    name        => 'mouse import and qc',
    datasource  => $ds,
    output_root => $output_dir,
    pipeline    => $import_qc_pipeline,
    options     => {
        reference_fasta         => $ref_fa,
        reference_assembly_name => 'GRCm38',
        reference_species       => 'Mus musculus',
        samtools_stats_options  => '-q 20',
        #exome_targets_file      => file(qw(t data pombe_ref.fa.targets))->absolute->stringify,
        cleanup => 1
    }
);

my @irods_files = (file($irods_dir, $irods_test_data_dir, '9417_4#1.MT.bam'), file($irods_dir, $irods_test_data_dir, '9417_4#2.MT.bam'), file($irods_dir, $irods_test_data_dir, '9417_4#3.MT.bam'), file($irods_dir, $irods_test_data_dir, '9417_4#4.MT.bam'));

my @qc_files;
my $element_id = 1;
my @lanes = ('9417_4#1.MT', '9417_4#2.MT', '9417_4#3.MT', '9417_4#4.MT');
foreach my $lane (@lanes) {
    my @output_subdirs = output_subdirs($element_id++);
    
    push(@qc_files, file(@output_subdirs, '3_samtools_bam_stats', $lane . '.bam.bamstats'));
    foreach my $kind (qw(quals-hm quals quals2 quals3 insert-size gc-content gc-depth acgt-cycles coverage mism-per-cycle indel-dist indel-cycles)) {
        push(@qc_files, file(@output_subdirs, '4_plot_bamstats', $lane . '-' . $kind . '.png'));
    }
}

ok handle_pipeline(@irods_files, @qc_files), 'bam_import_from_irods_and_qc pipeline ran ok and produced all expected output files';

# test that the pipeline stored the summary stats and plots under the
# VRTrack schema in the graph database, and associated it with the pipelinesetup
my $vr_imported_bam_file = $schema->get('File', { path => $irods_files[3]->stringify });
my $meta = $vr_imported_bam_file->properties(flatten_parents => 1);
delete $meta->{vrpipe_stepstate_uuid};
is_deeply $meta,
  {
    'taxon_common_name'                => 'Mouse',
    'lane_run'                         => '9417',
    'library_tag'                      => 'AGTGGTCA',
    'study_id'                         => '2547',
    'sample_accession'                 => 'ERS215819',
    'vrpipe_stepstate_sql_id'          => '4',
    'vrpipe_pipelinesetup_name'        => 'mouse import and qc',
    'library_id'                       => '6784054',
    'study_accession'                  => 'ERP002262',
    'vrpipe_pipelinesetup_user'        => 'vr-pipe',
    'sample_name'                      => 'MEK_res_4',
    'file_target'                      => '1',
    'file_manual_qc'                   => '1',
    'vrpipe_pipelinesetup_output_root' => $output_dir,
    'file_md5'                         => '3a44f834f2edc0f89278327dd6dbcff2',
    'sample_created_date'              => 1361433109,
    'file_path'                        => "$irods_test_data_dir/9417_4#4.MT.bam",
    'group_name'                       => 'all_studies',
    'library_name'                     => 'MEK_res_4 6784054',
    'taxon_id'                         => '10090',
    'path'                             => "$irods_dir$irods_test_data_dir/9417_4#4.MT.bam",
    'alignment_reference'              => '/lustre/scratch109/srpipe/references/Mus_musculus/GRCm38/all/bwa/Mus_musculus.GRCm38.68.dna.toplevel.fa',
    'study_name'                       => 'De novo and acquired resistance to MEK inhibitors ',
    'lane_lane'                        => '4',
    'lane_is_paired_read'              => '1',
    'sample_id'                        => '1571703',
    'vrpipe_pipelinesetup_id'          => '1',
    'lane_total_reads'                 => '62535326',
    'lane_unique'                      => '9417_4#4.MT',
    'library_platform'                 => 'ILLUMINA',
    'library_center_name'              => 'SC'
  },
  'related metadata in graph correct for one of the bam files';

ok my ($stats_file) = $vr_imported_bam_file->related(outgoing => { type => 'parsed', namespace => 'VRTrack', label => 'File' }), 'there was a stats file node attached to the imported bam file';
ok my ($bam_stats) = $stats_file->related(outgoing => { type => 'summary_stats', namespace => 'VRTrack', label => 'Bam_Stats' }), 'there was a bam_stats node attached to the stats file';
my $bs_props = $bam_stats->properties;
delete $bs_props->{uuid};
is_deeply $bam_stats->properties, { "bases trimmed" => "5832", "average quality" => "36.0", "mode" => "normal", "is sorted" => "1", "reads mapped after rmdup" => 166309, "mismatches" => "15501", "reads duplicated" => "19584", "bases of 2X coverage" => 16299, "bases of 10X coverage" => 15510, "bases of 5X coverage" => 16299, "raw total sequences" => 185893, "reads paired" => "185893", "maximum length" => "75", "insert size average" => "203.9", "non-primary alignments" => "0", "reads mapped and paired" => "184802", "reads after rmdup" => 166309, "bases of 1X coverage" => 16301, "bases duplicated" => "1468800", "bases of 50X coverage" => 13337, "average length" => "75", "1st fragments" => "93259", "reads properly paired" => "183082", "options" => "-r $ref_fa -q 20", "outward oriented pairs" => "510", "bases of 100X coverage" => 13085, "bases mapped (cigar)" => "13923850", "reads unmapped" => "0", "bases mapped" => 13941975, "filtered sequences" => "0", "inward oriented pairs" => "91580", "pairs with other orientation" => "0", "sequences" => "185893", "bases after rmdup" => 12473175, "reads MQ0" => "39911", "bases mapped after rmdup" => 12456960, "insert size standard deviation" => "82.3", "pairs on different chromosomes" => "233", "mean coverage" => "413.57", "reads mapped" => 185893, "bases of 20X coverage" => 13950, "error rate" => "1.113270e-03", "last fragments" => "92634", "reads QC failed" => "0", "total length" => 13941975 }, 'the bam_stats node had the correct stats';
my @plots = $stats_file->related(outgoing => { type => 'bamstats_plot', namespace => 'VRTrack', label => 'File' });
is scalar(@plots), 12, 'all the plots were attached to the stats file';

finish;
