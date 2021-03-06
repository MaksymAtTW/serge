package Serge::Engine::Job;
use parent Serge::Interface::PluginHost;

use strict;

no warnings qw(uninitialized);

use Data::Dumper;
use Serge::Util qw(subst_macros generate_hash is_flag_set);

#
# Initialize object
#
sub new {
    my ($class, $data, $engine, $base_dir) = @_;

    die "data not provided" unless $data;

    my $self = $data;

    # calculate hash before we add additional calculated fields and bless
    # the data
    my $dumper = Data::Dumper->new([$data]);
    $self->{hash} = generate_hash($dumper->Terse(1)->Deepcopy(1)->Indent(0)->Dump);

    $self->{engine} = $engine if $engine;
    $self->{base_dir} = $base_dir if $base_dir;

    $self->{debug} = undef;

    # Check job config validity

    die "job has no 'id' property" unless $self->{id};

    if (!exists $self->{destination_languages} or scalar(@{$self->{destination_languages}}) == 0) {
        die "the list of target languages is empty";
    }

    if (scalar @{$self->{destination_languages}} > 1) {
        if ($self->{ts_file_path} !~ m/%(LANG|LOCALE|CULTURE|LANGNAME|LANGID)(:\w+)*%/) {
            die "when there's more than one target language, 'ts_file_path' should have %LANG%, %LOCALE%, %CULTURE%, %LANGNAME%, or %LANGID% macro defined";
        }

        if ($self->{output_lang_files} && ($self->{output_file_path} !~ m/%(LANG|LOCALE|CULTURE|LANGNAME|LANGID)(:\w+)*%/)) {
            die "when there's more than one target language, 'output_file_path' should have %LANG%, %LOCALE%, %CULTURE%, %LANGNAME%, or %LANGID% macro defined";
        }
    }

    bless $self, $class;

    # load parser plugin

    $self->{parser_object} = $self->load_plugin_and_register_callbacks($self->{parser});

    my $plugin_name = $self->{parser}->{plugin};
    my $class = ref $self->{parser_object};
    $self->{plugin_version} = $plugin_name.'.'.eval('$'.$class.'::VERSION');

    # load callback plugins

    map {
        $self->load_plugin_and_register_callbacks($_);
    } @{$self->{callback_plugins}};

    return $self;
}

sub load_plugin_and_register_callbacks {
    my ($self, $node) = @_;

    my $plugin = $node->{plugin};

    my $p = $self->load_plugin_from_node('Serge::Engine::Plugin', $node);

    my @phases = $p->get_phases;

    # if specific phase was specified, limit to this specific phase
    if (exists $node->{phase}) {
        # check the validity of phase names
        my $used_phases = {};
        map {
            die "phase '$_' specified twice" if exists $used_phases->{$_};
            die "phase '$_' is not supported by '$node->{plugin}' plugin" unless is_flag_set(\@phases, $_);
            $used_phases->{$_} = 1;
        } @{$node->{phase}};

        @phases = @{$node->{phase}};
    }

    $p->adjust_phases(\@phases);

    foreach my $phase (@phases) {
        my $a = $self->{callback_phases}->{$phase};
        $self->{callback_phases}->{$phase} = $a = [] unless defined $a;
        push @$a, $p;
    }

    return $p;
}

sub run_callbacks {
    my ($self, $phase, @params) = @_;

    if (exists $self->{callback_phases}->{$phase}) {
        print "::phase '$phase' has callbacks, running...\n" if $self->{debug};

        my @result;

        foreach my $p (@{$self->{callback_phases}->{$phase}}) {
            my @res = $p->callback($phase, @params);
            print "::plugin '".ref($p)."' returned [".join(',', @res)."]\n" if $self->{debug};
            push @result, @res;
        }
        return @result;
    } else {
        print "::phase '$phase' has no callbacks defined\n" if $self->{debug};
    }
    return; # return nothing
}

sub get_hash {
    my ($self) = @_;
    return $self->{hash};
}

sub abspath {
    my ($self, $path) = @_;

    return Serge::Util::abspath($self->{base_dir}, $path);
}

sub get_full_ts_file_path {
    my ($self, $file, $lang) = @_;

    return subst_macros($self->{ts_file_path}, $file, $lang, $self->{source_language});
}

sub render_full_output_path {
    my ($self, $path, $file, $lang) = @_;

    # get the relative file path sans the source_path_prefix
    # note that this would be a virtual path that might have been changed
    # in rewrite_path callback
    my $prefix = $self->{source_path_prefix};
    $file =~ s/^\Q$prefix\E// if $prefix;

    my $r = $self->{output_lang_rewrite};
    $lang = $r->{$lang} if exists($r->{$lang});

    return subst_macros($path, $file, $lang, $self->{source_language});
}

sub gather_similar_languages_for_lang {
    my ($self, $lang) = @_;

    my %out;
    if (exists $self->{similar_languages}) {
        foreach my $rule (@{$self->{similar_languages}}) {
            if ($rule->{destination} eq $lang) {
                map { $out{$_} = 1 } @{$rule->{source}};
            }
        }
    }
    return keys %out;
}

1;