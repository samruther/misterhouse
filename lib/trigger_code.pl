use strict;

# Monitors trigger code, used by code like tv_grid and the web alarm page,
# that specifies events that trigger actions.  View, add, modify, or
# delete triggers with http://localhost:8080/bin/triggers.pl

# $Date$
# $Revision$

use vars '%triggers';           # use vars so we can use in the web server

my ($trigger_write_code_flag, $prev_triggers, $prev_script);
my $trigger_file = "$::config_parms{data_dir}/triggers.current";
my $expired_file = "$::config_parms{data_dir}/triggers.expired";
my $script_file  = "$::Code_Dirs[0]/triggers.mhp";

&::MainLoop_pre_add_hook (\&triggers_loop, 1);
&::Exit_add_hook         (\&triggers_save, 1);

sub triggers_loop {
    $prev_triggers = &file_read($trigger_file) if $Reload and -e $trigger_file;
    $prev_script   = &file_read($script_file)  if $Reload and -e $script_file;
    &triggers_save      if new_minute 5;
    &trigger_write_code if $trigger_write_code_flag;
}

# Read current triggers file at startup
sub triggers_read {
                                # Read trigger data
    return unless -e $trigger_file;

    my $i = 0;
    undef %triggers;

    my ($trigger, $code, $name, $type, $triggered);
    for my $record (&file_read($trigger_file), '') {
        if ($record =~ /\S/) {
            next if $record =~ /^ *#/;
            if ($record =~ /^name=(.+?)\s+type=(\S+)\s+triggered=(\d*)/) {
                $name = $1;  $type = $2; $triggered = $3;
            }
            elsif (!$trigger) {
                $trigger = $record;;
            }
            else {
                next if $record =~ /^\d+ \d+$/;  # Old trigger format ... ignore
                $code .= $record . "\n";
            }
        }
                          # Assume there is always a blank line at end of file
        elsif ($trigger) {
            trigger_set($trigger, $code, $type, $name, 1, $triggered);
            $trigger = $code = $name = $type = $triggered = '';
            $i++;
        }
    }
    print " - read $i trigger entries\n";
}

                                # Write trigger code
sub trigger_write_code {
    $trigger_write_code_flag = 0;
    my $script;
    foreach my $name (trigger_list()) {
        my ($trigger, $code, $type, $triggered) = trigger_get($name);
        next unless $trigger;
        $script .= "\n# name=$name type=$type\n";
        $script .= "if (($trigger) and &trigger_active('$name')) {\n";
        $script .= "    # FYI trigger code: $code;\n";
        $script .= "    &trigger_run('$name',1);\n}\n";
    }
    $script = "#\n#@ Do NOT edit.  This file is auto-generated by mh/lib/trigger_code.pl\n" .
              "#@ and reflects the data in $::config_parms{data_dir}/triggers.current\n#\n" . $script;
    return if $script eq $prev_script;
    $prev_script = $script;
    &file_write($script_file, $script);
                                # Replace (faster) or reload (if there was no file previously)
    if ($::Run_Members{'triggers_table'}) {
        &do_user_file("$::Code_Dirs[0]/triggers.mhp");
    }
    else {
                                # Must be done before the user code eval
        push @Nextpass_Actions, \&read_code;
    }

}

                                # Save and prune out expired triggers
sub triggers_save {
    my ($data, $data1, $data2, $i1, $i2);
    $i1 = $i2 = 0;
    $data1 = $data2 = '';
    foreach my $name (trigger_list()) {
        my ($trigger, $code, $type, $triggered) = trigger_get($name);
        next unless $trigger;
        $data  = "name=$name type=$type triggered=$triggered\n";
        $data .=  $trigger . "\n";
        $data .=  $code . ";\n";
                                # Prune it out if it is expired and > 1 week old
        if (trigger_expired($name) and ($triggers{$name}{triggered} + 60*60*24*7) < $Time) {
            $data2 .= $data . "\n";
            $i2++;
            delete $triggers{$name};
        }
        else {
            $data1 .= $data . "\n";
            $i1++;
        }
    }
    print_log "Saving triggers:  $i2 expired, $i1 saved" if $i2;
    $data1 = '#
# Note: Do NOT edit this file while mh is running (edits will be lost).
# It is used by mh/code/common/trigger_code.pl to auto-generate code_dir/triggers.mhp.
# It is updated by various trigger_ functions like trigger_set.
# Syntax is:
#   name=trigger name  type=trigger_type  triggered=triggered_time
#   trigger_clause
#     code_to_run
#     code_to_run
#
# Expired triggers will be pruned to triggers.expired a week after they expire.
#

' . $data1;
    $data2 = "# Expired on $Time_Date\n" . $data2 if $data2;
    unless ($data1 eq $prev_triggers) {
        &file_write($trigger_file, $data1);
        &logit($expired_file, $data2, 0) if $data2;
        $trigger_write_code_flag++;
    }
    $prev_triggers = $data1;
    return;
}

sub trigger_set {
    my ($trigger, $code, $type, $name, $replace, $triggered) = @_;

    print "trigger_set: trigger=$trigger code=$code name=$name\n" if $Debug{'trigger'};
    return unless $trigger and $code;

                                # Find a uniq name
    if (exists $triggers{$name} and $replace) {
        print_log "trigger $name already exists, modifying";
    }
    else {
        $name = time_date_stamp(12) unless $name;
        if (exists $triggers{$name}) {
            my $i = 2;
            while (exists $triggers{"$name $i"}) { $i++; }
            print_log "trigger $name already exists, adding '$i' to name";
            $name = "$name $i";
        }
    }

    $code =~ s/;?\n?$//;  # So we can consistenly add ;\n when used
    $triggered = 0 unless $triggered;
    $type  = 'OneShot' unless $type;
    $triggers{$name}{trigger} = $trigger;
    $triggers{$name}{code}    = $code;
    $triggers{$name}{triggered} = $triggered;
    $triggers{$name}{type}  = $type;
    $trigger_write_code_flag++;
    return;
}

sub trigger_get {
    my $name = shift;
    return 0 unless exists $triggers{$name};
    return 1 unless wantarray;
    return $triggers{$name}{trigger}, $triggers{$name}{code}, $triggers{$name}{type}, $triggers{$name}{triggered};
}

sub trigger_delete {
    my $name = shift;
    return unless exists $triggers{$name};
    delete $triggers{$name};
    $trigger_write_code_flag++;
    return;
}

sub trigger_copy {
    my $name = shift;
    my $name2 = "$name 2";
    return unless exists $triggers{$name};
    if (my ($r, $i) = $name =~ /(.+) (\d+)$/) {
        $name2 = "$r " . ++$i;
    }
    $triggers{$name2}{trigger}   = $triggers{$name}{trigger};
    $triggers{$name2}{code}      = $triggers{$name}{code};
    $triggers{$name2}{type}      = $triggers{$name}{type};
    $triggers{$name2}{triggered} = 0;
    return;
}

sub trigger_rename {
    my ($name1, $name2) = @_;
    return unless exists $triggers{$name1};
    $triggers{$name2}{trigger}   = $triggers{$name1}{trigger};
    $triggers{$name2}{code}      = $triggers{$name1}{code};
    $triggers{$name2}{type}      = $triggers{$name1}{type};
    $triggers{$name2}{triggered} = $triggers{$name1}{triggered};
    delete $triggers{$name1};
    $trigger_write_code_flag++;
    return;
}

sub trigger_run {
    my ($name,$expire) = @_;
    if (!exists $triggers{$name}) {
    	&print_log("Trigger '$name' does not exist");
    	return;
	}
	&trigger_expire($name) if $expire;
    my ($trigger, $code, $type, $triggered) = trigger_get($name);
    &print_log ("Running trigger code for: $name") if $Debug{trigger};
    eval $code;
    &print_log ("Finished running trigger code for: $name") if $Debug{trigger};
    if ($@) {
	    &print_log("Error: trigger '$name' failed to run cleanly");
	    &print_log("  Code = $code");
	    &print_log("  Result = $@");
	    # At this point we could opt to disable the trigger
	    # but it is likely more useful to have a repeating error message
	    # to let the user know that something is wrong
	}
    return;
}


sub trigger_list {
    return sort keys %triggers;
}

sub trigger_active {
    my $name = shift;
#   print "db n=$name t=$triggers{$name}{type} e=!$triggers{$name}{triggered}\n";
    return (exists $triggers{$name} and
        ($triggers{$name}{type} eq 'NoExpire' or $triggers{$name}{type} eq 'OneShot'));
}

sub trigger_expired {
    my $name = shift;
    return (exists $triggers{$name} and $triggers{$name}{type} eq 'Expired');
}

sub trigger_expire {
    my $name = shift;
    $triggers{$name}{triggered} = $Time;
    return unless exists $triggers{$name} and $triggers{$name}{type} eq 'OneShot';
#   print "db setting name=$name expire_time=$Time\n";
    $triggers{$name}{type}      = 'Expired';
    return;
}

1;
