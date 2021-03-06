﻿package Serge::Engine::Plugin::transform;
use parent Serge::Plugin::Base::Callback;

use strict;

use utf8;

use Digest::MD5 qw(md5);
use Encode qw(encode_utf8);
use Serge::Util;

my @transforms = ('wrappertag', 'tags', 'whitespace', 'case', 'endpunc'); # ordering is important!
my @combinations;
my $plugins = {};
my $initialized = undef;
my $mappings = {};

sub name {
    return 'Guess translations from similar already translated strings';
}

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    $self->merge_schema({
        as_fuzzy_default => 'BOOLEAN',
        as_fuzzy         => 'ARRAY',
        as_not_fuzzy     => 'ARRAY'
    });

    $self->{keys} = {};
    $self->{as_fuzzy_default} = 1; # by default, all guessed translations are returned as fuzzy
    $self->{as_fuzzy} = []; # list of languages for which guessed translations are always returned as fuzzy (despite the `as_fuzzy_default` setting)
    $self->{as_not_fuzzy} = []; # list of languages for which guessed translations are always returned as NOT fuzzy (despite the `as_fuzzy_default` setting)

    $self->add('get_translation', \&get_translation);
}

sub validate_data {
    my $self = shift;

    $self->SUPER::validate_data;

    map {
        $self->{$_} = $self->{data}->{$_} if exists $self->{data}->{$_};
    } qw(
        as_fuzzy_default
        as_fuzzy
        as_not_fuzzy
    );
}

sub adjust_phases {
    my ($self, $phases) = @_;

    # always tie to 'get_translation' phase
    set_flag($phases, 'get_translation');
}

sub _get_combinations {
    my ($base) = @_;

    my @digits;
    for (0 .. $base - 1) {
        push @digits, $_;
    }

    my %result;
    for (0 .. 2 ** $base - 2) { # do not include the highest value with all bits set to avoid empty number
        my @mask = split('', sprintf('%0'.$base.'b', $_));
        my @n = @digits;
        for (0 .. $base - 1) {
            $n[$_] = '' if $mask[$_];
        }

        $result{join('', @n)} = 1;
    }

    # sort by string length and by number
    return sort {
        my $result = length($a) <=> length($b);
        return $result == 0 ? $a cmp $b : $result
    } keys %result;
}

sub _load_plugins {
    print "Loading string transformation plugins\n";

    foreach my $plugin (@transforms) {
        eval(qq|use Serge::Engine::Plugin::Transform::$plugin; \$plugins->{$plugin} = Serge::Engine::Plugin::Transform::$plugin|.qq|->new();|);
        ($@) && die "Can't load callback plugin [Serge::Engine::Plugin::Transform::$plugin]: $@";
        print "\t'$plugin': ".$plugins->{$plugin}->name."\n";
    }
}

sub _filter_string {
    my $string = shift;
    foreach my $plugin (@transforms) {
        $string = $plugins->{$plugin}->filter_key($string);
    }
    return $string;
}

sub _make_key {
    my ($string) = @_;
    $string = _filter_string($string);
    return unless ($string ne '');
    return md5(encode_utf8($string));
}

sub make_key {
    my ($self, $string) = @_;
    my $key = md5(encode_utf8($string)); # original, unfiltered string
    return $self->{keys}->{$key} if exists $self->{keys}->{$key};
    return $self->{keys}->{$key} = _make_key($string);
}

sub lazy_initialize {
    my ($self) = @_;

    return if $initialized;

    _load_plugins;

    print "Calculating string transformation plugin combinations\n";

    @combinations = _get_combinations(scalar @transforms);

    print "Preloading cache for string transformations\n";

    my $sqlquery =
        "SELECT DISTINCT string ".
        "FROM strings ".
        "WHERE skip = 0";
    my $sth = $self->{parent}->{engine}->{db}->prepare($sqlquery);
    $sth->execute || die $sth->errstr;

    while (my $ar = $sth->fetchrow_arrayref()) {
        my $key = $self->make_key($ar->[0]);
        if (defined $key) {
            my $h = $mappings->{$key};
            $h = $mappings->{$key} = {} unless $h;
            $h->{$ar->[0]} = 1;
        }
    }

    $initialized = 1;
}

sub get_translation {
    my ($self, $phase, $string, $context, $namespace, $filepath, $lang, $disallow_similar_lang, $item_id) = @_;

    $self->lazy_initialize;

    my $key = $self->make_key($string);
    # if key is not defined (the string was empty after filtering), then
    # simply return the original string
    if (!$key) {
        # return: (translation, fuzzy_state, comment, db_save_flag)
        return ($string, undef, undef, 1); # return as NOT fuzzy, save to database
    }

    if (defined $key && exists $mappings->{$key}) {
        my ($guessed, $fuzzy) = $self->guess_translation($string, $context, $namespace, $filepath, $lang);
        if (defined $guessed) {
            print "Guessed translation: '$guessed'\n" if $self->{parent}->{debug};
            # return: (translation, fuzzy_state, comment, db_save_flag)
            return ($guessed, $fuzzy, undef, 1); # save to database
        } else {
            print "Failed to guess translation\n" if $self->{parent}->{debug};
        }
    } else {
        print "No similar strings for string '$string'\n" if $self->{parent}->{debug};
    }

    return (); # return empty array, not an 'undef' value and neither the original string
}

sub find_solution {
    my ($self, $a, $b) = @_;
    print "Finding solution to transform '$a' into '$b'\n" if $self->{parent}->{debug};

    foreach my $sequence (@combinations) {
        my @c = split('', $sequence);

        my $result = $self->apply_solution($a, $b, $sequence);

        if ($result && ($result eq $b)) {
            return $sequence;
        }
    }
    return undef;
}

sub apply_solution {
    my ($self, $a, $b, $solution, $lang) = @_;

    my @c = split('', $solution);
    my $s = $a;

    my $ok = 1;
    foreach my $n (@c) {
        my $name = $transforms[$n];
        $s = $plugins->{$name}->transform($s, $b, $lang);
    }
    return $ok ? $s : undef;
}

sub guess_translation {
    my ($self, $source, $context, $namespace, $filepath, $lang) = @_;

    my $key = $self->make_key($source);

    if ($self->{parent}->{debug}) {
        print "Trying to guess translation for string '$source'; candidates are:\n";
        foreach my $candidate (keys %{$mappings->{$key}})  {
            print "\t* '".$candidate."'\n" if $candidate ne $source;
        }
    }

    my $candidates = $mappings->{$key};

    if (keys %$candidates > 0) {
        foreach my $candidate (keys %$candidates) {
            next if ($candidate eq $source); # exact matches should be substituted outside this code

            my $solution = $self->find_solution($candidate, $source);
            if (defined $solution) {
                my $solution_text = join(' -> ', map { $transforms[$_] } split(//, $solution));
                print "\nSolution: '$candidate' -> $solution_text\n" if $self->{parent}->{debug};

                my ($translation, $fuzzy, $comment, $multiple_variants) = $self->{parent}->{engine}->{db}->find_best_translation($namespace, $filepath, $candidate, $context, $lang);
                if ($multiple_variants && !$self->{parent}->{reuse_uncertain}) {
                    print "Multiple translations found, won't reuse any because 'reuse_uncertain' mode is set to NO\n" if $self->{parent}->{debug};
                    undef $translation;
                }

                if ($translation ne '') {
                    print "Applying this solution to translation '$translation'\n" if $self->{parent}->{debug};
                    $translation = $self->apply_solution($translation, $source, $solution, $lang);

                    if ($fuzzy) {
                        # if the fuzzy flag is already set, always leave it as is,
                        # even if the language is listed under `as_not_fuzzy` list
                    } else {
                        # the fuzzy flag is not set, but we might want to raise it here
                        my $lang_as_fuzzy = is_flag_set($self->{as_fuzzy}, $lang);
                        my $lang_as_not_fuzzy = is_flag_set($self->{as_not_fuzzy}, $lang);
                        $fuzzy = 1 if $lang_as_fuzzy || ($self->{as_fuzzy_default} && !$lang_as_not_fuzzy);
                    }

                    return ($translation, $fuzzy);
                } else {
                    print "There's no translation for the candidate string\n" if $self->{parent}->{debug};
                }
            }
        }
    }

    return undef;
}

1;