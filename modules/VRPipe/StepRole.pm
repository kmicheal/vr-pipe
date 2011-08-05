use VRPipe::Base;

role VRPipe::StepRole {
    method name {
        my $class = ref($self);
        my ($name) = $class =~ /.+::(.+)/;
        return $name;
    }
    requires 'options_definition';
    requires 'inputs_definition';
    requires 'body_sub';
    requires 'post_process_sub';
    requires 'outputs_definition';
    requires 'description';
    
    # these may be needed by body_sub and post_process_sub
    has 'step_state' => (is => 'rw',
                         isa => 'VRPipe::StepState');
 
    has 'data_element' => (is => 'ro',
                           isa => 'VRPipe::DataElement',
                           builder => '_build_data_element',
                           lazy => 1);
    
    has 'output_root' => (is => 'ro',
                          isa => Dir,
                          coerce => 1,
                          builder => '_build_output_root',
                          lazy => 1);
    
    has 'options' => (is => 'ro',
                      isa => 'HashRef',
                      builder => '_resolve_options',
                      lazy => 1);
    
    has 'inputs' => (is => 'ro',
                     isa => PersistentFileHashRef,
                     builder => '_resolve_inputs',
                     lazy => 1);
    
    has 'outputs' => (is => 'ro',
                      isa => PersistentFileHashRef,
                      builder => '_build_outputs',
                      lazy => 1);
    has 'temps' => (is => 'ro',
                    isa => ArrayRefOfPersistent,
                    builder => '_build_temps',
                    lazy => 1);
    
    has 'previous_step_outputs' => (is => 'rw',
                                    isa => PreviousStepOutput);
    
    # when parse is called, we'll store our dispatched refs here
    has 'dispatched' => (is => 'ro',
                         traits  => ['Array'],
                         isa     => 'ArrayRef',
                         lazy    => 1,
                         default => sub { [] },
                         handles => { _dispatch => 'push',
                                      num_dispatched  => 'count' });
    
    # and we'll also store all the output files the body_sub makes
    has '_output_files' => (is => 'ro',
                            traits  => ['Hash'],
                            isa     => 'HashRef',
                            lazy    => 1,
                            default => sub { {} },
                            handles => { _remember_output_files => 'set' });
    has '_temp_files' => (is => 'ro',
                          traits  => ['Array'],
                          isa     => 'ArrayRef',
                          lazy    => 1,
                          default => sub { [] },
                          handles => { _remember_temp_file => 'push' });
    has '_last_output_dir' => (is => 'rw',
                               isa => Dir,
                               lazy => 1,
                               coerce => 1,
                               builder => '_build_last_output_dir');
    
    method _build_data_element {
        my $step_state = $self->step_state || $self->throw("Cannot get data element without step state");
        return $step_state->dataelement;
    }
    method _build_output_root {
        my $step_state = $self->step_state || $self->throw("Cannot get output root without step state");
        my $pipeline_root = $step_state->pipelinesetup->output_root;
        return dir($pipeline_root, $step_state->dataelement->id, $self->name);
    }
    method _build_last_output_dir {
        return $self->output_root;
    }
    method _build_outputs {
        my $step_state = $self->step_state || $self->throw("Cannot get outputs without step state");
        return $step_state->output_files;
    }
    method _build_temps {
        my $step_state = $self->step_state || $self->throw("Cannot get outputs without step state");
        return $step_state->temp_files;
    }
    
    method _resolve_options {
        my $step_state = $self->step_state || $self->throw("Cannot get options without step state");
        my $user_opts = $step_state->pipelinesetup->options;
        my $hash = $self->options_definition;
        
        my %return;
        while (my ($key, $val) = each %$hash) {
            if ($val->isa('VRPipe::StepOption')) {
                my $user_val = $user_opts->{$key};
                if (defined $user_val) {
                    my $allowed = $val->allowed_values;
                    if (@$allowed) {
                        my %allowed = map { $_ => 1 } @$allowed;
                        if (exists $allowed{$user_val}) {
                            $return{$key} = $user_val;
                        }
                        else {
                            $self->throw("'$user_val' is not an allowed option for '$key'");
                        }
                    }
                    else {
                        $return{$key} = $user_val;
                    }
                }
                elsif (! $val->optional) {
                    $self->throw("the option '$key' is required");
                }
                else {
                    my $default = $val->default_value;
                    if (defined $default) {
                        $return{$key} = $default;
                    }
                }
            }
            else {
                $self->throw("invalid class ".ref($val)." supplied for option '$key' definition");
            }
        }
        
        # add in requirements overrides that pertain to us
        my $name = $self->name;
        foreach my $resource (qw(memory time cpus tmp_space local_space custom)) {
            my $user_key = $name.'_'.$resource;
            if (defined $user_opts->{$user_key}) {
                $return{$resource.'_override'} = $user_opts->{$user_key};
            }
        }
        
        return \%return;
    }
    
    method _resolve_inputs {
        my $hash = $self->inputs_definition;
        my $step_num = $self->step_state->stepmember->step_number;
        my $step_adaptor = VRPipe::StepAdaptor->get(pipeline => $self->step_state->stepmember->pipeline, to_step => $step_num);
        
        my %return;
        while (my ($key, $val) = each %$hash) {
            if ($val->isa('VRPipe::File')) {
                $return{$key} = [$val];
            }
            elsif ($val->isa('VRPipe::StepIODefinition')) {
                # see if we have this $key in our previous_step_outputs or
                # via the options or data_element
                my $results;
                
                my $pso = $self->previous_step_outputs;
                if ($pso) {
                    # can our StepAdaptor adapt previous step output to this
                    # input key?
                    $results = $step_adaptor->adapt(input_key => $key, pso => $pso);
                }
                if (! $results) {
                    # can our StepAdaptor translate our dataelement into a file
                    # for this key?
                    $results = $step_adaptor->adapt(input_key => $key, data_element => $self->data_element);
                }
                if (! $results) {
                    my $opts = $self->options;
                    if ($opts && defined $opts->{$key}) {
                        $results = [VRPipe::File->get(path => $opts->{$key})];
                    }
                }
                
                if (! $results) {
                    $self->throw("the input file(s) for '$key' of stepstate ".$self->step_state->id." could not be resolved");
                }
                
                my $num_results = @$results;
                my $max_allowed = $val->max_files;
                my $min_allowed = $val->min_files;
                if ($max_allowed == -1) {
                    $max_allowed = $num_results;
                }
                if ($min_allowed == -1) {
                    $min_allowed = $num_results;
                }
                unless ($num_results >= $min_allowed && $num_results <= $max_allowed) {
                    $self->throw("there were $num_results input file(s) for '$key' of stepstate ".$self->step_state->id.", which does not fit the allowed range $min_allowed..$max_allowed");
                }
                
                my @vrfiles;
                foreach my $result (@$results) {
                    unless (ref($result) && ref($result) eq 'VRPipe::File') {
                        $result = VRPipe::File->get(path => file($result)->absolute);
                    }
                    
                    my $type = VRPipe::FileType->create($val->type, {file => $result->path});
                    unless ($type->check_type) {
                        $self->throw("file ".$result->path." was not the correct type");
                    }
                    
                    push(@vrfiles, $result);
                }
                
                $return{$key} = \@vrfiles;
            }
            else {
                $self->throw("invalid class ".ref($val)." supplied for input '$key' value definition");
            }
        }
        
        return \%return;
    }
    
    method _missing (PersistentFileHashRef $hash, PersistentHashRef $defs) {
        # check that we don't have any outputs defined in the definition that
        # no files were made for
        while (my ($key, $val) = each %$defs) {
            next if exists $hash->{$key};
            $self->throw("'$key' was defined as an output, yet no output file was made with that output_key");
        }
        
        my @missing;
        # check the files we actually output are as expected
        while (my ($key, $val) = each %$hash) {
            my $def = $defs->{$key};
            my $check_s = 1;
            if ($def && $def->isa('VRPipe::StepIODefinition')) {
                $check_s = $def->check_existence;
            }
            
            foreach my $file (@$val) {
                if ($check_s && ! $file->s) {
                    push(@missing, $file->path);
                }
                else {
                    my $bad = 0;
                    
                    # check the filetype is correct
                    my $type = VRPipe::FileType->create($file->type, {file => $file->path});
                    unless ($type->check_type) {
                        $self->warn($file->path." exists, but is the wrong type!");
                        $bad = 1;
                    }
                    
                    # check the expected metadata keys exist
                    if ($def && $def->isa('VRPipe::StepIODefinition')) {
                        my @needed = $def->required_metadata_keys;
                        if (@needed) {
                            my $meta = $file->metadata;
                            foreach my $key (@needed) {
                                unless (exists $meta->{$key}) {
                                    $self->warn($file->path." exists, but lacks metadata key $key!");
                                    $bad = 1;
                                }
                            }
                        }
                    }
                    
                    if ($bad) {
                        push(@missing, $file->path);
                    }
                }
            }
        }
        
        return @missing;
    }
    
    method missing_input_files {
        return $self->_missing($self->inputs, $self->inputs_definition);
    }
    
    method missing_output_files {
        return $self->_missing($self->outputs, $self->outputs_definition);
    }
    
    method _run_coderef (Str $method_name) {
        my $ref = $self->$method_name();
        return &$ref($self);
    }
    
    method output_file (Str :$output_key, File|Str :$basename, FileType :$type, Dir|Str :$output_dir?, Dir|Str :$sub_dir?, HashRef :$metadata?, Bool :$temporary = 0) {
        #*** for some bizarre reason, type can be left out and the checking doesn't complain!
        $self->throw("type must be supplied") unless $type;
        
        $output_dir ||= $self->output_root;
        $output_dir = dir($output_dir);
        if ($sub_dir) {
            $output_dir = dir($output_dir, $sub_dir);
        }
        $self->throw("output_dir must be absolute ($output_dir)") unless $output_dir->is_absolute;
        $self->make_path($output_dir); #*** repeated, potentially unecessary filesystem access...
        $self->_last_output_dir($output_dir);
        
        my $vrfile = VRPipe::File->get(path => file($output_dir, $basename), type => $type);
        $vrfile->add_metadata($metadata) if $metadata;
        
        my $hash = $self->_output_files;
        my $files = $hash->{$output_key} || [];
        push(@$files, $vrfile);
        $self->_remember_output_files($output_key => $files);
        
        if ($temporary) {
            my $root = $self->output_root;
            $self->throw("temporary files must be placed within the output_root") unless $output_dir =~ /^$root/;
            $self->_remember_temp_file($vrfile);
        }
        
        return $vrfile;
    }
    
    method set_cmd_summary (VRPipe::StepCmdSummary $cmd_summary) {
        my $step_state = $self->step_state;
        $step_state->cmd_summary($cmd_summary);
        $step_state->update;
    }
    
    method parse {
        my @missing = $self->missing_input_files;
        $self->throw("Required input files are missing: (@missing)") if @missing;
        
        $self->_run_coderef('body_sub');
        
        # store output and temp files on the StepState
        my $output_files = $self->_output_files;
        if (keys %$output_files) {
            my $step_state = $self->step_state;
            $step_state->output_files($output_files);
            $step_state->update;
        }
        my $temp_files = $self->_temp_files;
        if (@$temp_files) {
            my $step_state = $self->step_state;
            $step_state->temp_files($temp_files);
            $step_state->update;
        }
        
        # return true if we've finished the step
        my $dispatched = $self->num_dispatched;
        if ($dispatched) {
            return 0;
        }
        else {
            return $self->post_process;
        }
    }
    
    method post_process {
        my $ok = $self->_run_coderef('post_process_sub');
        my $debug_desc = "step ".$self->name." failed for data element ".$self->data_element->id." and pipelinesetup ".$self->step_state->pipelinesetup->id;
        my $stepstate = $self->step_state;
        if ($ok) {
            my @missing = $self->missing_output_files;
            $stepstate->unlink_temp_files;
            if (@missing) {
                $self->throw("Some output files are missing (@missing) for $debug_desc");
            }
            else {
                return 1;
            }
        }
        else {
            $stepstate->unlink_temp_files;
            $self->throw("The post-processing part of $debug_desc");
        }
    }
    
    method new_requirements (Int :$memory, Int :$time, Int :$cpus?, Int :$tmp_space?, Int :$local_space?, HashRef :$custom?) {
        # user can override settings set in the step body_sub by providing
        # options
        my $options = $self->options;
        if (defined $options->{memory_override}) {
            $memory = $options->{memory_override};
        }
        if (defined $options->{time_override}) {
            $time = $options->{time_override};
        }
        #*** and the other resources?...
        
        return VRPipe::Requirements->get(memory => $memory,
                                         time => $time,
                                         $cpus ? (cpus => $cpus) : (),
                                         $tmp_space ? (tmp_space => $tmp_space) : (),
                                         $local_space ? (local_space => $local_space) : (),
                                         $custom ? (custom => $custom) : ());
    }
    
    method dispatch (ArrayRef $aref) {
        my $extra_args = $aref->[2] || {};
        $extra_args->{dir} ||= $self->_last_output_dir;
        $aref->[2] = $extra_args;
        $self->_dispatch($aref);
    }
    
    method dispatch_vrpipecode (Str $code, VRPipe::Requirements $req, HashRef $extra_args?) {
        my $deployment = VRPipe::Persistent::SchemaBase->database_deployment;
        
        # use lib for anything that has been added to INC
        my $use_lib = '';
        use lib;
        my %orig_inc = map { $_ => 1 } @lib::ORIG_INC;
        my @new_lib;
        foreach my $inc (@INC) {
            unless (exists $orig_inc{$inc}) {
                push(@new_lib, file($inc)->absolute);
            }
        }
        if (@new_lib) {
            $use_lib = "use lib(qw(@new_lib)); ";
        }
        
        my $cmd = qq[perl -MVRPipe::Persistent::Schema -e "${use_lib}VRPipe::Persistent::SchemaBase->database_deployment(q[$deployment]); $code"];
        $self->dispatch([$cmd, $req, $extra_args]);
    }
    
    method dispatch_md5sum (VRPipe::File $vrfile, Maybe[Str] $expected_md5) {
        my $path = $vrfile->path;
        my $req = $self->new_requirements(memory => 500, time => 1);
        
        if ($expected_md5) {
            return $self->dispatch_vrpipecode(qq[use Digest::MD5; open(FILE, q[$path]) or die q[Could not open file $path]; binmode(FILE); if (Digest::MD5->new->addfile(*FILE)->hexdigest eq q[$expected_md5]) { VRPipe::File->get(path => q[$path], md5 => q[$expected_md5]); } else { die q[md5sum of $path does not match expected value] }],
                                              $req);
        }
        else {
            return $self->dispatch_vrpipecode(qq[use Digest::MD5; open(FILE, q[$path]) or die q[Could not open file $path]; binmode(FILE); VRPipe::File->get(path => q[$path], md5 => Digest::MD5->new->addfile(*FILE)->hexdigest);],
                                              $req);
        }
    }
    
    # using this lets you run a bunch of perl code wrapping a command line exe,
    # yet still keep the command line visible so you know the most important
    # bit of what was run
    method dispatch_wrapped_cmd (ClassName $class, Str $method, ArrayRef $dispatch_args) {
        my ($cmd, $req, $extra_args) = @$dispatch_args;
        
        $class->can($method) || $self->throw("$method is not a valid method of $class");
        my $code = $class->isa('VRPipe::Persistent') ? '' : "use $class; ";
        $code .= "$class->$method(q[$cmd]);";
        
        my @args = ($code, $req);
        push(@args, $extra_args) if $extra_args;
        
        return $self->dispatch_vrpipecode(@args);
    }
}

1;