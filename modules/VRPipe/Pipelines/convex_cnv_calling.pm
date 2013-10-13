
=head1 NAME

VRPipe::Pipelines::convex_cnv_calling - a pipeline

=head1 DESCRIPTION

This is third of three pipeline required to run in sequence in order to
generate CNV Calls using the Convex Exome CNV detection package. This pipeline
generates CNV calls from the Read Depth and L2R files, generated by the
previous pipelines convex_read_depth_generation and convex_l2r_bp_generation.
Its datasource will probably a vrpipe datasource from the convex_read_depth
Step of the convex_read_depth_generation pipeline.

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

class VRPipe::Pipelines::convex_cnv_calling with VRPipe::PipelineRole {
    method name {
        return 'convex_cnv_calling';
    }
    
    method description {
        return 'Run CoNVex pipeline to Generate CNV calls from Read Depth and L2R files';
    }
    
    method step_names {
        (
            'convex_gam_correction', #1
            'convex_cnv_call',       #2
        );
    }
    
    method adaptor_definitions {
        (
            { from_step => 0, to_step => 1, to_key   => 'rd_files' },
            { from_step => 0, to_step => 1, to_key   => 'l2r_files' },
            { from_step => 1, to_step => 2, from_key => 'gam_files', to_key => 'gam_files' }
        );
    }
}

1;
