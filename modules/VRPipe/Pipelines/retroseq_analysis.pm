
=head1 NAME

VRPipe::Pipelines::retroseq_analysis - a pipeline

=head1 DESCRIPTION

Runs Retroseq genotyping of Transposable Elements from short read alignments,
generating VCFs of TE calls for a bam datasource.

=head1 AUTHOR

Chris Joyce <cj5@sanger.ac.uk>.

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

class VRPipe::Pipelines::retroseq_analysis with VRPipe::PipelineRole {
    method name {
        return 'retroseq_analysis';
    }
    
    method description {
        return 'Run retroseq genotyping of transposable elements from short read alignments';
    }
    
    method step_names {
        (
            'bam_index',
            'retroseq_discover',
            'retroseq_call',
        );
    }
    
    method adaptor_definitions {
        (
            { from_step => 0, to_step => 1, to_key   => 'bam_files' },
            { from_step => 0, to_step => 2, to_key   => 'bam_files' },
            { from_step => 0, to_step => 3, to_key   => 'bam_files' },
            { from_step => 2, to_step => 3, from_key => 'rseq_bed', to_key => 'rseq_bed' }
        );
    }
    
    method behaviour_definitions {
        ({ after_step => 3, behaviour => 'delete_outputs', act_on_steps => [2], regulated_by => 'cleanup', default_regulation => 1 });
    }
}

1;
