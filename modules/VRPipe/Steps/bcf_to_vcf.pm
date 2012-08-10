
=head1 NAME

VRPipe::Steps::bcf_to_vcf - a step

=head1 DESCRIPTION

Generates a compressed VCF from a BCF file using bcftools view, optionally
restricting output on samples or sites

=head1 AUTHOR

Chris Joyce <cj5@sanger.ac.uk>.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2011-2012 Genome Research Limited.

This file is part of VRPipe.

VRPipe is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see L<http://www.gnu.org/licenses/>.

=cut

use VRPipe::Base;

class VRPipe::Steps::bcf_to_vcf with VRPipe::StepRole {
    method options_definition {
        return { bcftools_exe          => VRPipe::StepOption->create(description => 'path to bcftools executable',                                                                                                                                                                                          optional => 1, default_value => 'bcftools'),
                 bcftools_view_options => VRPipe::StepOption->create(description => 'bcftools view options',                                                                                                                                                                                                optional => 1, default_value => '-p 0.99 -vcgN'),
                 sample_sex_file       => VRPipe::StepOption->create(description => 'File listing the sex (M or F) of samples. If not provided, will call on all samples in the bcf header. If provided, calls will be made on the intersection of the samples in the file and samples in the bcf header.', optional => 1),
                 assumed_sex           => VRPipe::StepOption->create(description => 'If M or F is not present for a sample in the sample sex file, then this sex is assumed',                                                                                                                               optional => 1, default_value => 'F') };
    }
    
    method inputs_definition {
        return { bcf_files  => VRPipe::StepIODefinition->create(type => 'bcf', max_files => -1, description => '1 or more bcf files to convert to compressed vcf'),
                 sites_file => VRPipe::StepIODefinition->create(type => 'txt', min_files => 0,  max_files   => 1, description => 'Optional sites file for calling only at the given sites'), };
    }
    
    method body_sub {
        return sub {
            my $self        = shift;
            my $options     = $self->options;
            my $bcftools    = $options->{bcftools_exe};
            my $view_opts   = $options->{bcftools_view_options};
            my $assumed_sex = $options->{assumed_sex};
            my $sample_sex_file;
            if ($options->{sample_sex_file}) {
                $sample_sex_file = Path::Class::File->new($options->{sample_sex_file});
                $self->throw("sample_sex_file must be an absolute path") unless $sample_sex_file->is_absolute;
            }
            if ($self->inputs->{sites_file}) {
                $self->throw("bcftools_view_options cannot contain the -l option if a sites_file is an input to this step") if ($view_opts =~ /-l/);
                my $sites_file = $self->inputs->{sites_file}[0];
                $view_opts .= " -l " . $sites_file->path;
            }
            
            my $req = $self->new_requirements(memory => 500, time => 1);
            foreach my $bcf (@{ $self->inputs->{bcf_files} }) {
                my $bcf_meta = $bcf->metadata;
                my $bcf_path = $bcf->path;
                my $basename = $bcf->basename;
                $basename =~ s/\.bcf$//;
                $bcf_meta->{caller} = 'samtools_mpileup_bcftools';
                
                my $female_ploidy = defined $bcf_meta->{female_ploidy} ? delete $bcf_meta->{female_ploidy} : 2;
                my $male_ploidy   = defined $bcf_meta->{male_ploidy}   ? delete $bcf_meta->{male_ploidy}   : 2;
                
                my $temp_samples_path = $self->output_file(basename => $basename . '.samples', type => 'txt', temporary => 1)->path;
                
                my $vcf_file = $self->output_file(output_key => 'vcf_files', basename => $basename . '.vcf.gz', type => 'vcf', metadata => $bcf_meta);
                my $vcf_path = $vcf_file->path;
                my $cmd_line = qq[$bcftools view $view_opts -s $temp_samples_path $bcf_path | bgzip -c > $vcf_path];
                
                my $bcf_id = $bcf->id;
                my $args   = qq['$cmd_line', '$temp_samples_path', source_file_ids => ['$bcf_id'], female_ploidy => '$female_ploidy', male_ploidy => '$male_ploidy', assumed_sex => '$assumed_sex'];
                $args .= qq[, sample_sex_file => '$sample_sex_file'] if $sample_sex_file;
                my $cmd = "use VRPipe::Steps::bcf_to_vcf; VRPipe::Steps::bcf_to_vcf->bcftools_call_with_sample_file($args);";
                $self->dispatch_vrpipecode($cmd, $req, { output_files => [$vcf_file] });
            }
            
            $self->set_cmd_summary(VRPipe::StepCmdSummary->create(exe     => 'bcftools',
                                                                  version => VRPipe::StepCmdSummary->determine_version($bcftools, '^Version: (.+)$'),
                                                                  summary => "bcftools view $view_opts -s \$samples_file \$bcf_file | bgzip -c > \$vcf_file"));
        };
    }
    
    method outputs_definition {
        return { vcf_files => VRPipe::StepIODefinition->create(type => 'vcf', max_files => -1, description => 'a .vcf.gz file for each input bcf file') };
    }
    
    method post_process_sub {
        return sub { return 1; };
    }
    
    method description {
        return "Run bcftools view option to generate one compressed vcf file per input bcf. Will take care of ploidy if sample_sex_file is provided and bcf files contain male_ploidy and female_ploidy metadata.";
    }
    
    method max_simultaneous {
        return 0;            # meaning unlimited
    }
    
    method source_samples (ClassName|Object $self: ArrayRef[Int] $source_file_ids) {
        my %source_samples;
        foreach my $file_id (@$source_file_ids) {
            my $file = VRPipe::File->get(id => $file_id);
            if ($file->type eq 'bcf') {
                my $bcf_ft = VRPipe::FileType->create('bcf', { file => $file->path });
                map { $source_samples{$_} = 1 } @{ $bcf_ft->samples };
            }
            elsif ($file->type eq 'bam') {
                my $bp = VRPipe::Parser->create('bam', { file => $file });
                map { $source_samples{$_} = 1 } $bp->samples;
                $bp->close;
            }
            else {
                $self->throw("Source file not of type bcf or bam, " . $file->path);
            }
        }
        $self->throw("No samples found") unless (keys %source_samples);
        return \%source_samples;
    }
    
    method bcftools_call_with_sample_file (ClassName|Object $self: Str $cmd_line!, Str|File $sample_ploidy_path, ArrayRef[Int] :$source_file_ids!, Str|File :$sample_sex_file?, Int :$female_ploidy!, Int :$male_ploidy!, Str :$assumed_sex = 'F') {
        my $source_samples = $self->source_samples($source_file_ids);
        my $ploidy_file = VRPipe::File->get(path => $sample_ploidy_path);
        
        my %samples;
        if ($sample_sex_file) {
            my $sex_file = VRPipe::File->create(path => $sample_sex_file);
            my $fh = $sex_file->openr;
            while (<$fh>) {
                chomp;
                my ($sample, $sex) = split /\t/;
                next unless (exists $source_samples->{$sample});
                $sex ||= $assumed_sex;
                $samples{$sample} = $sex;
            }
            $fh->close;
        }
        else {
            foreach my $sample (keys %$source_samples) {
                $samples{$sample} = $assumed_sex;
            }
        }
        
        my $pfh              = $ploidy_file->openw;
        my $expected_samples = 0;
        while (my ($sample, $sex) = each %samples) {
            my $ploidy = $sex eq 'F' ? $female_ploidy : $male_ploidy;
            next unless $ploidy; ## ploidy may be zero. eg chromY for female samples
            print $pfh "$sample\t$ploidy\n";
            $expected_samples++;
        }
        $pfh->close;
        $ploidy_file->update_stats_from_disc(retries => 3);
        
        # check number of samples is as expected
        my $actual_samples = $ploidy_file->lines;
        unless ($actual_samples == $expected_samples) {
            $ploidy_file->unlink;
            $self->throw("write_sample_ploidy_file failed because $actual_samples samples were generated in the output ploidy files, yet we expected $expected_samples samples");
        }
        
        my ($output_path) = $cmd_line =~ /> (\S+)$/;
        my $output_file = VRPipe::File->get(path => $output_path);
        $output_file->disconnect;
        system($cmd_line) && $self->throw("failed to run [$cmd_line]");
        $output_file->update_stats_from_disc(retries => 3);
    }
}

1;
