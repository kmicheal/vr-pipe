
=head1 NAME

VRPipe::Persistent::Graph - interface to a graph database

=head1 SYNOPSIS
    
use VRPipe::Persistent::Graph;

my $graph = VRPipe::Persistent::Graph->new();

$graph->add_schema(     namespace => 'QCGrind',     label => 'Sample',    
unique => [qw(sanger_id uuid)],         indexed => [qw(public_name)] );

my $node = $graph->add_node(     namespace => 'QCGrind',     label => 'Sample',
    properties => {         sanger_id => 'sanger1',         uuid => 'uuuuu',   
     public_name => 'public1'     } );

$graph->relate($node, $other_node, 'has');

($node) = $graph->get_nodes(     namespace => 'QCGrind',     label => 'Sample',
    properties => {         public_name => 'public1'     } );

my ($related_node) = $graph->related_nodes(     $node,     namespace =>
'QCGrind',     label => 'Lane',     max_depth => 4 );

=head1 DESCRIPTION

For schema-less store of connected data we use a graph database; Neo4J in this
case.

This is essentially a wrapper around REST::Neo4p, providing functions that can
be used to store and retrieve information about things.

Things (must) have a namespace, label and properties. A dynamically-applied
"schema" must be in place first, providing uniqueness constraints and indexes.

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

class VRPipe::Persistent::Graph {
    use VRPipe::Config;
    use VRPipe::Persistent::SchemaBase;
    use REST::Neo4p;
    use Data::UUID;
    
    our $data_uuid  = Data::UUID->new();
    our $vrp_config = VRPipe::Config->new();
    our ($neo4p, $global_label, $schemas, $schema_labels);
    
    sub BUILD {
        my $self = shift;
        
        unless ($neo4p) {
            my $url = $vrp_config->neo4j_server_url();
            $neo4p = REST::Neo4p->connect($url);
            
            my $deployment = VRPipe::Persistent::SchemaBase->database_deployment;
            if ($deployment eq 'production') {
                $global_label = "vdp";
            }
            else {
                my $user = getlogin || getpwuid($<);
                $global_label = "vdt$user";
            }
            $schema_labels = qq[`$global_label`:`Schema`];
        }
    }
    
    sub _run_cypher {
        my ($self, $cypher, $params) = @_;
        my $query = REST::Neo4p::Query->new($cypher, $params ? ({ param => $params }) : ());
        $query->execute;
        if ($query->err) {
            $self->throw("neo4j cypher query failed with code " . $query->err . ": " . $query->errstr);
        }
        else {
            my @results;
            while (my $row = $query->fetch) {
                push(@results, @$row > 1 ? $row : $row->[0]);
                #*** when we ask for a node neo4j will return the full details of the node, but it seems like neo4p only creates an object consisting of the id? maybe we should avoid object construction entirely and only return ID(node)?
            }
            return @results;
        }
    }
    
    method drop_database {
        $self->throw("drop_database() can only be used when testing") unless $global_label =~ /^vdt/;
        
        # drop all schemas (which drops all constraints and indexes)
        my @schema_nodes = $self->_run_cypher("MATCH (n:$schema_labels) RETURN n");
        foreach my $node (@schema_nodes) {
            my $schema = $node->get_property('schema');
            my (undef, $namespace, $label) = split(/\|/, $schema);
            $self->drop_schema(namespace => $namespace, label => $label);
        }
        
        # drop all nodes and relationships
        $self->_run_cypher("MATCH (n:`$global_label`) OPTIONAL MATCH (n:`$global_label`)-[r]-() DELETE n,r");
        
        return 1;
    }
    
    sub _deployment_specific_label {
        my ($self, $namespace, $label) = @_;
        return "$global_label|$namespace|$label";
    }
    
    method add_schema (Str :$namespace!, Str :$label!, ArrayRef[Str] :$unique!, ArrayRef[Str] :$indexed?, ArrayRef[Str] :$required?) {
        # namespace and label cannot contain |
        foreach ($namespace, $label) {
            if (index($_, '|') != -1) {
                $self->throw("neither namespace or label may contain the | character");
            }
        }
        
        # have we already done this?
        my $dsl = $self->_deployment_specific_label($namespace, $label);
        my ($done) = $self->_run_cypher("MATCH (n:$schema_labels { schema: '$dsl' }) RETURN n");
        unless ($done) {
            # set constraints (which also adds an index on the constraint)
            foreach my $field (@$unique) {
                if (index($field, '|') != -1) {
                    $self->throw("parameter may not contain the | character");
                }
                $self->_run_cypher("CREATE CONSTRAINT ON (n:`$dsl`) ASSERT n.$field IS UNIQUE");
            }
            
            # add indexes
            foreach my $field (@{ $indexed || [] }) {
                if (index($field, '|') != -1) {
                    $self->throw("parameter may not contain the | character");
                }
                $self->_run_cypher("CREATE INDEX ON :`$dsl`($field)");
            }
            
            # record that we've done this
            my $unique_fields = join('|', @$unique);
            my $indexed_arg = $indexed ? q[, indexed: '] . join('|', @$indexed) . q['] : '';
            my $required_arg = $required ? q[, required: '] . join('|', @$required) . q['] : '';
            $self->_run_cypher("CREATE (:$schema_labels { schema: '$dsl', unique: '$unique_fields'$indexed_arg$required_arg })");
            
            $schemas->{$dsl} = [$unique, $indexed || [], $required || []];
            
            return 1;
        }
        return 0;
    }
    
    method get_schema (Str :$namespace!, Str :$label!) {
        my $dsl = $self->_deployment_specific_label($namespace, $label);
        if (exists $schemas->{$dsl}) {
            return @{ $schemas->{$dsl} };
        }
        else {
            my ($schema) = $self->_run_cypher("MATCH (n:$schema_labels { schema: '$dsl' }) RETURN n");
            if ($schema) {
                my $uniques  = [split(/\|/, $schema->get_property('unique'))];
                my $indexed  = [split(/\|/, $schema->get_property('indexed') || '')];
                my $required = [split(/\|/, $schema->get_property('required') || '')];
                $schemas->{$dsl} = [$uniques, $indexed, $required];
                return ($uniques, $indexed, $required);
            }
        }
    }
    
    method drop_schema (Str :$namespace!, Str :$label!) {
        my ($uniques, $indexed) = $self->get_schema(namespace => $namespace, label => $label);
        my $dsl = $self->_deployment_specific_label($namespace, $label);
        
        # remove constraints
        foreach my $field (@$uniques) {
            $self->_run_cypher("DROP CONSTRAINT ON (n:`$dsl`) ASSERT n.$field IS UNIQUE");
        }
        
        # remove indexes
        foreach my $field (@$indexed) {
            $self->_run_cypher("DROP INDEX ON :`$dsl`($field)");
        }
        
        # remove the node storing schema details, and our cache
        $self->_run_cypher("MATCH (n:$schema_labels { schema: '$dsl' })-[r]-() DELETE n, r");
        delete $schemas->{$dsl};
    }
    
    sub _labels_and_param_map {
        my ($self, $namespace, $label, $params, $check_required) = @_;
        
        # check that we have a schema for this
        my ($uniques, $indexed, $required) = $self->get_schema(namespace => $namespace, label => $label);
        $self->throw("You must first create a schema for namespace `$namespace` and label `$label`") unless $uniques;
        if ($check_required) {
            $self->throw("Parameters must be supplied") unless $params;
            foreach my $param (@$uniques, @{ $required || [] }) {
                $self->throw("Parameter '$param' must be supplied") unless defined $params->{$param};
            }
        }
        
        my $labels = "`$global_label`:`$global_label|$namespace|$label`";
        my $param_map = $params ? ' { ' . join(', ', map { "$_: {param}.$_" } sort keys %$params) . ' }' : '';
        return ($labels, $param_map);
    }
    
    method add_node (Str :$namespace!, Str :$label!, HashRef :$properties!) {
        my ($labels, $param_map) = $self->_labels_and_param_map($namespace, $label, $properties, 1);
        
        if (defined wantarray()) {
            my ($node) = $self->_run_cypher("MERGE (n:$labels$param_map) RETURN n", $properties);
            return $node;
        }
        else {
            $self->_run_cypher("MERGE (:$labels$param_map)", $properties);
        }
    }
    
    method delete_node (Object $node!) {
        my $id = $node->id();
        $self->_run_cypher("START n=node($id) MATCH n-[r]-() DELETE n, r");
        return 1;
    }
    
    sub create_uuid {
        return $data_uuid->create_str();
    }
    
    method get_nodes (Str :$namespace!, Str :$label!, HashRef :$properties!) {
        my ($labels, $param_map) = $self->_labels_and_param_map($namespace, $label, $properties);
        return $self->_run_cypher("MATCH (n:$labels$param_map) RETURN n", $properties);
    }
    
    method relate (Object $start_node!, Object $end_node!, Str $relationship!) {
        #*** is there a benefit to constructing our own cypher query here instead?
        return $start_node->relate_to($end_node, $relationship);
    }
    
    method related_nodes (Object $start_node!, Str :$namespace!, Str :$label!, HashRef :$properties?, Str :$relationship?, Str :$direction?, Int :$min_depth = 1, Int :$max_depth = 1) {
        my ($labels, $param_map) = $self->_labels_and_param_map($namespace, $label, $properties);
        my $type = $relationship ? ":`$relationship`" : '';
        $direction ||= '';
        my $leftward  = $direction eq '<' ? '<' : '';
        my $rightward = $direction eq '>' ? '>' : '';
        return $self->_run_cypher("START start=node(" . $start_node->id . ") MATCH (start)$leftward-[$type*$min_depth..$max_depth]-$rightward(n:$labels$param_map) RETURN n", $properties);
    }
}

1;
