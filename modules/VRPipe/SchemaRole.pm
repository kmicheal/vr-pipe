
=head1 NAME

VRPipe::SchemaRole - a role that must be used by all Schemas

=head1 SYNOPSIS
    
    use VRPipe::Base;
    class VRPipe::Schema::MySchema with VRPipe::SchemaRole {
        method schema_definitions {
            return [
                {
                    label => 'Building',
                    unique => [qw(coordinates)],
                    indexed => [qw(name)],
                    required => [qw(name)],
                    optional => [qw(size)],
                }
            ];
        }
    }
    1;
    
    # then users can (see VRPipe::Schema docs for more):
    my $myschema = VRPipe::Schema->create('MySchema');
    my $building = $myschema->get('Building', { coordinates => 'xyz' });
    my $name = $building->name();
    $building->name('foo');

=head1 DESCRIPTION

Have a schema_definitions method that returns an array ref of hash refs, where
the hashes are the args you would supply to
VRPipe::Persistent::Graph->add_schema(), except for namespace, which will be
the class name. You can also add an additional 'optional' key to specify other
allowed attributes. Any attribute not specified somewhere in unique/indexed/
required/optional will not be get/settable via the auto-created
VRPipe::Schemas::MySchema::[label] class to which returned nodes will belong.

=head1 AUTHOR

Sendu Bala <sb10@sanger.ac.uk>.

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2014 Genome Research Limited.

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

role VRPipe::SchemaRole {
    use VRPipe::Persistent::InMemory;
    use VRPipe::Persistent::Graph;
    my $graph = VRPipe::Persistent::Graph->new();
    
    has 'schemas' => (
        is      => 'ro',
        isa     => 'ArrayRef',
        lazy    => 1,
        builder => 'schema_definitions'
    );
    
    has 'namespace' => (
        is      => 'ro',
        isa     => 'Str',
        lazy    => 1,
        builder => '_build_namespace'
    );
    
    has 'labels' => (
        traits  => ['Hash'],
        is      => 'ro',
        isa     => 'HashRef[ArrayRef[Str]]',
        default => sub { {} },
        handles => {
            _add_label       => 'set',
            valid_label      => 'exists',
            label_properties => 'get',
        },
    );
    
    has '_historical_labels' => (
        traits  => ['Hash'],
        is      => 'ro',
        isa     => 'HashRef[Bool]',
        default => sub { {} },
        handles => {
            _set_historical => 'set',
            _is_historical  => 'exists'
        },
    );
    
    has '_labels_that_allow_anything' => (
        traits  => ['Hash'],
        is      => 'ro',
        isa     => 'HashRef[Bool]',
        default => sub { {} },
        handles => {
            _set_anything_allowed => 'set',
            _allows_anything      => 'exists'
        },
    );
    
    method _build_namespace {
        my ($namespace) = ref($self) =~ /::([^:]+)$/;
        return $namespace;
    }
    
    method add_schemas {
        my $graph     = VRPipe::Persistent::Graph->new();
        my $namespace = $self->namespace;
        
        foreach my $def (@{ $self->schemas }) {
            # create constraints and indexes in the database
            my $optional       = delete $def->{optional};
            my $historical     = delete $def->{keep_history};
            my $allow_anything = delete $def->{allow_anything};
            $graph->add_schema(%$def, namespace => $namespace);
            
            # store on ourselves what's valid according to this definition
            my $label = $def->{label};
            my @label_properties = (@{ $def->{unique} || [] }, @{ $def->{indexed} || [] }, @{ $def->{required} || [] }, @{ $optional || [] });
            $self->_add_label($label => \@label_properties);
            $self->_set_historical($label => 1) if $historical;
            $self->_set_anything_allowed($label => 1) if $allow_anything;
            
            # create a class for this label
            my $methods = {};
            foreach my $property (@label_properties) {
                my $sub = sub {
                    shift->_get_setter($property, @_);
                };
                $methods->{ lc($property) } = $sub;
            }
            
            $methods->{unique_properties} = sub {
                @{ $def->{unique} || [] };
            };
            
            $methods->{required_properties} = sub {
                @{ $def->{required} || [] };
            };
            
            $methods->{other_properties} = sub {
                (@{ $def->{indexed} || [] }, @{ $optional || [] });
            };
            
            $methods->{_keep_history} = sub {
                return $historical;
            };
            
            $methods->{allows_anything} = sub {
                return $allow_anything;
            };
            
            $methods->{namespace} = sub {
                return $namespace;
            };
            
            $methods->{label} = sub {
                return $label;
            };
            
            $methods->{class} = sub {
                return $namespace . '::' . $label;
            };
            
            my $class = Moose::Meta::Class->create(
                'VRPipe::Schema::' . $namespace . '::' . $label,
                roles   => ['VRPipe::SchemaLabelRole', 'VRPipe::Base::Debuggable'],
                methods => $methods
            );
        }
    }
    
    method graph {
        return $graph;
    }
    
    method _get_and_bless_nodes (Str $label!, Str $graph_method!, HashRef|ArrayRef[HashRef] $properties?, HashRef $extra_graph_args?) {
        my $namespace = $self->namespace;
        unless ($self->valid_label($label)) {
            $self->throw("'$label' isn't a valid label for schema $namespace");
        }
        
        my $props;
        if ($properties) {
            $props = ref($properties) eq 'HASH' ? [$properties] : $properties;
            
            unless ($self->_allows_anything($label)) {
                # check the supplied properties are allowed ($graph checks that required
                # ones are supplied)
                my %valid_props = map { $_ => 1 } @{ $self->label_properties($label) };
                foreach my $prop_hash (@$props) {
                    foreach my $prop (keys %$prop_hash) {
                        unless (defined $prop_hash->{$prop}) {
                            delete $prop_hash->{$prop};
                            next;
                        }
                        
                        unless (exists $valid_props{$prop}) {
                            $self->throw("Property '$prop' supplied, but that isn't defined in the schema for ${namespace}::$label");
                        }
                    }
                }
            }
            
            if ($graph_method eq 'get_nodes') {
                $props = $properties;
            }
        }
        
        my @nodes = $graph->$graph_method(namespace => $namespace, label => $label, $props ? (properties => $props, ($graph_method eq 'add_nodes' ? (update => 1) : ())) : (), $namespace eq 'PropertiesWithHistory' ? (return_history_nodes => 1) : (), %{ $extra_graph_args || {} });
        
        # bless the nodes into the appropriate class
        foreach my $node (@nodes) {
            bless $node, 'VRPipe::Schema::' . $namespace . '::' . $label;
        }
        
        if (wantarray()) {
            return @nodes;
        }
        else {
            return $nodes[0];
        }
    }
    
    method add (Str $label!, HashRef|ArrayRef[HashRef] $properties!, HashRef :$incoming?, HashRef :$outgoing?) {
        my $history_props;
        my @nodes = $self->_get_and_bless_nodes($label, 'add_nodes', $properties, { $incoming ? (incoming => $incoming) : (), $outgoing ? (outgoing => $outgoing) : () });
        
        if ($self->_is_historical($label)) {
            foreach my $node (@nodes) {
                $node->_maintain_property_history(0);
            }
        }
        
        if (wantarray()) {
            return @nodes;
        }
        else {
            return $nodes[0];
        }
    }
    
    method get (Str $label!, HashRef $properties?) {
        return $self->_get_and_bless_nodes($label, 'get_nodes', $properties ? ($properties) : ());
    }
    
    method delete ($node) {
        my ($history_data, $im, $lock_key);
        if ($node->_keep_history) {
            # also delete any PropertyGroup nodes attached which hold our history
            # (and any Property nodes which are not used by something else - we lock
            #  to ensure we don't delete these during an update elsewhere)
            $im       = VRPipe::Persistent::InMemory->new();
            $lock_key = 'graph.propertieswithhistory.updating';
            $im->block_until_locked($lock_key);
            
            my $node_id        = $node->node_id();
            my $group_label    = $graph->_labels('PropertiesWithHistory', 'PropertyGroup');
            my $property_label = $graph->_labels('PropertiesWithHistory', 'Property');
            # (I can't figure out how to do this in a single cypher query)
            $history_data = $graph->_run_cypher([["MATCH (n)-[*1..500]->(g:$group_label) where id(n) = $node_id RETURN g"], ["MATCH (n)-[*1..500]->(g:$group_label)-->(p:$property_label) where id(n) = $node_id MATCH (p)<-[r]-() with p,count(r) as rs where rs = 1 RETURN p"]], { return_history_nodes => 1 });
        }
        
        $graph->delete_node($node);
        
        if ($lock_key) {
            foreach my $child (@{ $history_data->{nodes} }) {
                $graph->delete_node($child);
            }
            
            $im->unlock($lock_key);
        }
    }
    
    method create_uuid {
        return $graph->create_uuid();
    }
    
    method date_to_epoch (Str $date) {
        return $graph->date_to_epoch($date);
    }
}

1;
