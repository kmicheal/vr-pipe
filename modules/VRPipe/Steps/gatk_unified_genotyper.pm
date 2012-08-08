
=head1 NAME

VRPipe::Steps::gatk_unified_genotyper - a step

=head1 DESCRIPTION

*** more documentation to come

=head1 AUTHOR

Shane McCarthy <sm15@sanger.ac.uk>.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012 Genome Research Limited.

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

#Example generic command for UnifiedGenotyper GATK v1.3
# java -jar GenomeAnalysisTK.jar \
#   -R resources/Homo_sapiens_assembly18.fasta \
#   -T UnifiedGenotyper \
#   -I sample1.bam [-I sample2.bam ...] \
#   -o snps.raw.vcf \
#   -stand_call_conf [50.0] \
#   -stand_emit_conf 10.0 \
#   -dcov [50] \

class VRPipe::Steps::gatk_unified_genotyper extends VRPipe::Steps::gatk {
    around options_definition {
        return {
            %{ $self->$orig }, # gatk options
            unified_genotyper_options => VRPipe::StepOption->create(description => 'options for GATK UnifiedGenotyper, excluding -R,-D,-I,-o'), };
    }
    
    method inputs_definition {
        return { bam_files  => VRPipe::StepIODefinition->create(type => 'bam', max_files => -1, description => '1 or more bam files to call variants'),
                 sites_file => VRPipe::StepIODefinition->create(type => 'vcf', min_files => 0,  max_files   => 1, description => 'Optional sites file for calling only at the given sites'), };
    }
    
    method body_sub {
        return sub {
            my $self    = shift;
            my $options = $self->options;
            $self->handle_standard_options($options);
            
            my $reference_fasta = $options->{reference_fasta};
            my $genotyper_opts  = $options->{unified_genotyper_options};
            
            if ($self->inputs->{sites_file}) {
                $self->throw("unified_genotyper_options cannot contain the -alleles or --genotyping_mode (-gt_mode) options if a sites_file is an input to this step") if ($genotyper_opts =~ /-alleles/ || $genotyper_opts =~ /-gt_mode/ || $genotyper_opts =~ /--genotyping_mode/);
                my $sites_file = $self->inputs->{sites_file}[0];
                $genotyper_opts .= "--genotyping_mode GENOTYPE_GIVEN_ALLELES --alleles " . $sites_file->path;
            }
            
            my $req = $self->new_requirements(memory => 1200, time => 1);
            my $jvm_args = $self->jvm_args($req->memory);
            
            my $bams_list = $self->output_file(basename => "bams.list", type => 'txt', temporary => 1);
            my $bams_list_path = $bams_list->path;
            $self->create_fofn($bams_list, $self->inputs->{bam_files});
            my $vcf_meta = $self->common_metadata($self->inputs->{bam_files});
            $vcf_meta->{caller} = 'GATK_UnifiedGenotyper';
            
            my $element_meta = $self->step_state->dataelement->result;
            my $basename;
            if (defined $element_meta->{chrom}) {
                my $chrom  = $element_meta->{chrom};
                my $from   = $element_meta->{from};
                my $to     = $element_meta->{to};
                my $region = "${chrom}_${from}-${to}";
                $$vcf_meta{chrom}  = $chrom;
                $$vcf_meta{region} = $region;
                $$vcf_meta{seq_no} = $element_meta->{chunk_id};
                my $override_file = $element_meta->{chunk_override_file};
                my $override      = do $override_file;
                
                if (exists $$override{$region}{unified_genotyper_options}) {
                    $genotyper_opts = $$override{$region}{unified_genotyper_options};
                }
                $self->set_cmd_summary(VRPipe::StepCmdSummary->create(exe     => 'GenomeAnalysisTK',
                                                                      version => $self->gatk_version(),
                                                                      summary => 'java $jvm_args -jar GenomeAnalysisTK.jar -T UnifiedGenotyper -R $reference_fasta -I $bams_list -o $vcf_file -L $region ' . $genotyper_opts));
                $basename = "$region.gatk.vcf.gz";
                $genotyper_opts .= " -L $chrom:$from-$to";
            }
            else {
                $self->set_cmd_summary(VRPipe::StepCmdSummary->create(exe     => 'GenomeAnalysisTK',
                                                                      version => $self->gatk_version(),
                                                                      summary => 'java $jvm_args -jar GenomeAnalysisTK.jar -T UnifiedGenotyper -R $reference_fasta -I $bams_list -o $vcf_path ' . $genotyper_opts));
                $basename = 'gatk.vcf.gz';
            }
            
            my $vcf_file = $self->output_file(output_key => 'gatk_vcf_file', basename => $basename, type => 'vcf', metadata => $vcf_meta);
            my $vcf_path = $vcf_file->path;
            
            my $cmd = $self->java_exe . qq[ $jvm_args -jar ] . $self->jar . qq[ -T UnifiedGenotyper -R $reference_fasta -I $bams_list_path -o $vcf_path $genotyper_opts];
            $self->dispatch([$cmd, $req, { output_files => [$vcf_file] }]);
        
        };
    }
    
    method outputs_definition {
        return { gatk_vcf_file => VRPipe::StepIODefinition->create(type => 'vcf', max_files => 1, description => 'a single vcf file') };
    }
    
    method post_process_sub {
        return sub { return 1; };
    }
    
    method description {
        return "Run GATK UnifiedGenotyper for one or more BAMs, generating one compressed VCF per set of BAMs. Sites list can be provided";
    }
    
    method max_simultaneous {
        return 0;            # meaning unlimited
    }
}

1;
