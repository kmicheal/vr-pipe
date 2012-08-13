
=head1 NAME

VRPipe::Steps::mpileup_bcf - a step

=head1 DESCRIPTION

Runs samtools mpileup for one or more BAMs, generating one BCF file per set of
BAMs

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

class VRPipe::Steps::mpileup_bcf with VRPipe::StepRole {
    method options_definition {
        return { samtools_exe             => VRPipe::StepOption->create(description => 'path to samtools executable',                                                                                                   optional => 1, default_value => 'samtools'),
                 samtools_mpileup_options => VRPipe::StepOption->create(description => 'samtools mpileup options excluding -f and -b options. Also exclude -l option a sites_file is provided as an input to the step', optional => 1, default_value => '-DSV -C50 -m2 -F0.0005 -d 10000 -g'),
                 reference_fasta          => VRPipe::StepOption->create(description => 'absolute path to reference genome fasta'), };
    }
    
    method inputs_definition {
        return { bam_files  => VRPipe::StepIODefinition->create(type => 'bam', max_files => -1, description => '1 or more bam files to call variants'),
                 sites_file => VRPipe::StepIODefinition->create(type => 'txt', min_files => 0,  max_files   => 1, description => 'Optional sites file for calling only at the given sites'), };
    }
    
    method body_sub {
        return sub {
            my $self            = shift;
            my $options         = $self->options;
            my $samtools        = $options->{samtools_exe};
            my $reference_fasta = Path::Class::File->new($options->{reference_fasta});
            $self->throw("reference_fasta must be an absolute path") unless $reference_fasta->is_absolute;
            my $mpileup_opts = $options->{samtools_mpileup_options};
            if ($mpileup_opts =~ /-f|-b|$reference_fasta/) {
                $self->throw("samtools_mpileup_options should not include the reference, the -f or the -b options");
            }
            if ($self->inputs->{sites_file}) {
                $self->throw("samtools_mpileup_options cannot contain the -l option if a sites_file is an input to this step") if ($mpileup_opts =~ /-l/);
                my $sites_file = $self->inputs->{sites_file}[0];
                $mpileup_opts .= " -l " . $sites_file->path;
            }
            
            my $bams_list = $self->output_file(basename => "bams.list", type => 'txt', temporary => 1);
            my $bams_list_path = $bams_list->path;
            $bams_list->create_fofn($self->inputs->{bam_files});
            my @input_ids = map { $_->id } @{ $self->inputs->{bam_files} };
            my $bcf_meta = $self->common_metadata($self->inputs->{bam_files});
            
            my $element_meta = $self->step_state->dataelement->result;
            my $basename;
            if (defined $element_meta->{chrom}) {
                my $chrom  = $element_meta->{chrom};
                my $from   = $element_meta->{from};
                my $to     = $element_meta->{to};
                my $region = "${chrom}_${from}-${to}";
                $$bcf_meta{chrom}  = $chrom;
                $$bcf_meta{from}   = $from;
                $$bcf_meta{to}     = $to;
                $$bcf_meta{seq_no} = $element_meta->{chunk_id};
                my $override_file = $element_meta->{chunk_override_file};
                my $override      = do $override_file;
                
                if (exists $override->{"$region"}->{samtools_exe}) {
                    $samtools = $override->{"$region"}->{samtools_exe};
                }
                if (exists $override->{"$region"}->{samtools_mpileup_options}) {
                    $mpileup_opts = $override->{"$region"}->{samtools_mpileup_options};
                }
                $self->set_cmd_summary(VRPipe::StepCmdSummary->create(exe     => 'samtools',
                                                                      version => VRPipe::StepCmdSummary->determine_version($samtools, '^Version: (.+)$'),
                                                                      summary => "samtools mpileup $mpileup_opts -r \$region -f \$reference_fasta -b \$bam_files_list > \$bcf_file"));
                $basename = "$region.mpileup.bcf";
                $mpileup_opts .= " -r $chrom:$from-$to";
            }
            else {
                $basename = 'mpileup.bcf';
                $self->set_cmd_summary(VRPipe::StepCmdSummary->create(exe     => 'samtools',
                                                                      version => VRPipe::StepCmdSummary->determine_version($samtools, '^Version: (.+)$'),
                                                                      summary => "samtools mpileup $mpileup_opts -f \$reference_fasta -b \$bam_files_list > \$bcf_file"));
            }
            
            my $bcf_file = $self->output_file(output_key => 'bcf_files', basename => $basename, type => 'bcf', metadata => $bcf_meta);
            my $bcf_path = $bcf_file->path;
            
            my $req = $self->new_requirements(memory => 500, time => 1);
            
            my $cmd      = qq[$samtools mpileup $mpileup_opts -f $reference_fasta -b $bams_list_path > $bcf_path];
            my $this_cmd = "use VRPipe::Steps::mpileup_bcf; VRPipe::Steps::mpileup_bcf->mpileup_bcf_and_check(q[$cmd], input_ids => [qw(@input_ids)]);";
            $self->dispatch_vrpipecode($this_cmd, $req, { output_files => [$bcf_file] });
        };
    }
    
    method outputs_definition {
        return { bcf_files => VRPipe::StepIODefinition->create(type => 'bcf', max_files => -1, description => 'a .bcf file for each set of input bam files') };
    }
    
    method post_process_sub {
        return sub { return 1; };
    }
    
    method description {
        return "Run samtools mpileup for one or more bams, generating one bcf file per set of bams";
    }
    
    method max_simultaneous {
        return 0;            # meaning unlimited
    }
    
    method mpileup_bcf_and_check (ClassName|Object $self: Str $cmd_line!, ArrayRef[Int] :$input_ids!) {
        my ($fofn_path, $output_path) = $cmd_line =~ /-b (\S+) > (\S+)$/;
        $fofn_path   || $self->throw("cmd_line [$cmd_line] was not constructed as expected");
        $output_path || $self->throw("cmd_line [$cmd_line] was not constructed as expected");
        
        my $fofn = VRPipe::File->get(path => $fofn_path);
        my $bcf = VRPipe::FileType->create('bcf', { file => $output_path });
        my $bcf_file = VRPipe::File->get(path => $output_path);
        
        # my $ofh = $fofn->openw;
        # foreach my $input_id (@$input_ids) {
        #     my $file = VRPipe::File->get(id => $input_id);
        #     my $file_path = $file->path;
        #     print $ofh "$file_path\n";
        # }
        # $ofh->close;
        # $fofn->update_stats_from_disc(retries => 3);
        # $self->throw("fofn ".$fofn_path." does not contain all input files") unless ($fofn->lines == scalar @$input_ids);
        
        $bcf_file->disconnect;
        system($cmd_line) && $self->throw("failed to run [$cmd_line]");
        
        $bcf_file->update_stats_from_disc(retries => 3);
        
        if ($bcf->check_magic) {
            return 1;
        }
        else {
            $bcf_file->unlink;
            $self->throw("cmd [$cmd_line] failed because index file $output_path had the incorrect magic");
        }
    }
}

1;
