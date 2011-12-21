use VRPipe::Base;

class VRPipe::Steps::vcf_vep_consequences with VRPipe::StepRole {
    method options_definition {
        return { 'vcf2consequences_options' => VRPipe::StepOption->get(description => 'options to vcf2consequences_vep, excluding -v and -i'),
                 'vcf2consequences_exe' => VRPipe::StepOption->get(description => 'path to your vcf2consequences executable',
                                                               optional => 1,
                                                               default_value => 'vcf2consequences_vep'),
		 'tabix_exe' => VRPipe::StepOption->get(description => 'path to your tabix executable',
                                                        optional => 1,
                                                        default_value => 'tabix') };
    }
    method inputs_definition {
        return { vcf_files => VRPipe::StepIODefinition->get(type => 'vcf',
                                                            description => 'annotated vcf files',
                                                            max_files => -1),
        		vep_txt => VRPipe::StepIODefinition->get(type => 'txt',
                                                             description => 'vep analysis output file',
                                                             max_files => -1) };
    }
	method body_sub {
		return sub {
			my $self = shift;

			my $options = $self->options;
			my $tabix_exe = $options->{tabix_exe};
			my $con_exe = $options->{'vcf2consequences_exe'};
			my $con_opts = $options->{'vcf2consequences_options'};

			if ($con_opts =~ /-[v,i]/) {
				$self->throw("vcf2consequences_options should not include the -i or -v option");
			}

			my $req = $self->new_requirements(memory => 5000, time => 1);

			my $i;
			for($i=0;$i<@{$self->inputs->{vcf_files}};$i++) {
				my $vcf_file = $self->inputs->{vcf_files}[$i];
				my $vep_txt = $self->inputs->{vep_txt}[$i];

				my $basename = $vcf_file->basename;
				if ($basename =~ /\.vcf.gz$/) {
					$basename =~ s/\.vcf.gz$/.conseq.vcf.gz/;
				}
				else {
					$basename =~ s/\.vcf$/.conseq.vcf/;
				}
				my $conseq_vcf = $self->output_file(output_key => 'conseq_vcf', basename => $basename, type => 'vcf');
				my $tbi = $self->output_file(output_key => 'tbi_file', basename => $basename.'.tbi', type => 'bin');

				my $input_path = $vcf_file->path;
				my $output_path = $conseq_vcf->path;
				my $vep_txt_path = $vep_txt->path;

				my $this_cmd = "$con_exe -v $input_path -i $vep_txt_path $con_opts | bgzip -c > $output_path; $tabix_exe -f -p vcf $output_path";

				$self->dispatch_wrapped_cmd('VRPipe::Steps::vcf_vep_consequences', 'consequence_vcf', [$this_cmd, $req, {output_files => [$conseq_vcf, $tbi]}]);
			}
		};
	}
    method outputs_definition {
        return { conseq_vcf => VRPipe::StepIODefinition->get(type => 'vcf',
                                                             description => 'annotated vcf file with VEP consequences',
                                                             max_files => -1),
                 tbi_file => VRPipe::StepIODefinition->get(type => 'bin',
                                                           description => 'a tbi file',
                                                           max_files => -1) };
    }
    method post_process_sub {
        return sub { return 1; };
    }
    method description {
        return "VCF annotated files with VEP consequences";
    }
    method max_simultaneous {
        return 0; # meaning unlimited
    }
    
    method consequence_vcf (ClassName|Object $self: Str $cmd_line) {
        my ($input_path, $output_path) = $cmd_line =~ /\S+ -v (\S+) .* vcf (\S[^;]+)$/;
        my $input_file = VRPipe::File->get(path => $input_path);
        
        my $input_lines = $input_file->lines;
        
        $input_file->disconnect;
        system($cmd_line) && $self->throw("failed to run [$cmd_line]");
        
        my $output_file = VRPipe::File->get(path => $output_path);
        $output_file->update_stats_from_disc;
        my $output_lines = $output_file->lines;
        
	# Should have an extra header line, but possible that duplicate header lines were removed
        unless ($output_lines >= $input_lines) {
            $output_file->unlink;
            $self->warn("Output VCF has $output_lines lines, less than input $input_lines");
        }
        else {
            return 1;
        }
    }
}

1;