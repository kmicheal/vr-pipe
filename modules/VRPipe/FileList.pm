
=head1 NAME

VRPipe::FileList - store an unordered list of VRPipe::File objects

=head1 SYNOPSIS

*** more documentation to come

=head1 DESCRIPTION

These lists are immutable and insensitive to order.

Both get() and create() will return an existing list if one had previously been
created using the supplied list of members. Both will also create and return a
new list if one had not been previously created.

=head1 AUTHOR

Sendu Bala <sb10@sanger.ac.uk>.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2013 Genome Research Limited.

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

class VRPipe::FileList extends VRPipe::Persistent with VRPipe::PersistentListRole {
    sub _member_class { 'VRPipe::FileListMember' }
    sub _member_key   { 'file' }
    sub _foreign_key  { 'filelist' }
    
    has 'lookup' => (
        is     => 'rw',
        isa    => Varchar [64],
        traits => ['VRPipe::Persistent::Attributes'],
        is_key => 1
    );
    
    __PACKAGE__->make_persistent(has_many => [members => 'VRPipe::FileListMember']);
    
    around get (ClassName|Object $self: Persistent :$id?, ArrayRef[VRPipe::File] :$files?) {
        return $self->_get_list($orig, $id, $files);
    }
    
    around create (ClassName|Object $self: ArrayRef[VRPipe::File] :$files!) {
        return $self->_create_list($orig, $files);
    }
    
    method files {
        return $self->_instantiated_members;
    }
}

1;
