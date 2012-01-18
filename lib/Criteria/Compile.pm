#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  Copyright (C) 2011 - Anthony J. Lucas - kaoyoriketsu@ansoni.com



package Criteria::Compile;



use strict;
use warnings;



our $VERSION = '0.04__2';



use UNIVERSAL ( );
use Tie::IxHash ( ); 



#INIT CONFIG / VARS


use constant HANDLER_DIE_MSG => 'Failed to compile `%s`. %s';

use constant {
    TYPE_STATIC => 10,
    TYPE_CHAINED => 20,
    TYPE_DYNAMIC => 30
};

my $DEFAULT_CRITERIA_DISPATCH_TBL = {
    TYPE_STATIC() => {},
    TYPE_CHAINED() => {},
    TYPE_DYNAMIC() => {
        qw/^(.*)_like$/ => qw/_gen_like_sub/,
        qw/^(.*)_matches$/ => qw/_gen_matches_sub/,
        qw/^(.*)_is$/ => qw/_gen_is_sub/,
        qw/^(.*)_in$/ => qw/_gen_in_sub/,
        qw/^(.*)_less_than$/ => qw/_gen_less_than_sub/,
        qw/^(.*)_greater_than$/ => qw/_gen_greater_than_sub/,
    }
};

use constant {
    ACC_HASH => 'HASH',
    ACC_OBJECT => 'OBJECT'
};

my $DEFAULT_ACCESS_MODE_TBL = {
    ACC_OBJECT() => sub {
        my ($ob, $attr) = @_;
        return &UNIVERSAL::can($ob, $attr)
            ? $ob->$attr()
            : undef;
    },
    ACC_HASH() => sub {
        return $_[0]->{$_[1]};
    }
}; 



#INITIALISATION ROUTINES


sub new {

    my ($class, %crit) = @_;
    my $self = {
        dispatch_tbl => {},
        access_tbl => {},
        exec_sub => sub { 1 },
        criteria => []
    };

    $self = bless($self, $class);
    $self->_init(\%crit);
    return $self;
}


sub _init {

    my ($self, $crit) = @_;

    #initialise default criteria dispatch tbls
    my $ordered_dt = ($self->{dispatch_tbl} = {});
    foreach (keys(%$DEFAULT_CRITERIA_DISPATCH_TBL)) {
        #perserve order
        tie(my %dt, 'Tie::IxHash')
            ->Push(%{$DEFAULT_CRITERIA_DISPATCH_TBL->{$_}});
        $ordered_dt->{$_} = \%dt;
    }

    #initialise default access mode tbl
    $self->{access_tbl} = {%$DEFAULT_ACCESS_MODE_TBL};
    $self->access_mode(ACC_OBJECT);

    #validate any criteria supplied
    if ($crit) {
        die('Error: Failed to compile criteria.')
            unless ($self->add_criteria(%$crit)
                and $self->compile());
    }
    return 1;
}



#CRTIERIA COMPILATION ROUTINES


sub export_sub {
    my $self = $_[0];
    $self->compile() unless ($self->{exec_sub});
    $self->{exec_sub};
}


sub exec {
    my $self = shift;
    $self->compile() unless ($self->{exec_sub});
    $self->{exec_sub}->(@_);
}


sub add_criteria {
    my $self = shift;
    return 1 unless (@_ > 0);
    $self->{exec_sub} = undef;

    push(@{$self->{criteria}}, {@_});
    return 1;
}


sub define_criteria {
    my $self = $_[0];
    (scalar(@_) > 2) and 
        ($self->{dispatch_tbl}->{$_[2]}
            = $self->_bless_handler($_[3]));
}


sub access_mode {
    my ($self, $mode) = @_;
    if ($mode = $self->{access_tbl}->{$mode}) {
        no warnings;
        *getter = $mode;
        return 1;
    }
    return 0;
}


sub define_access_mode {
    my ($self, $mode, $getter) = @_;
    my $a_tbl = $self->{access_tbl};
    #define mode if not already present
    unless ((!$mode or !$getter)
        or $a_tbl->{$mode}) {
        $a_tbl->{$mode} = $getter;
    }
    return 0;
}


sub compile {
	
    my ($self, $crit) = @_;
    my @action_list = ();
    my @crit_list = @{$self->{criteria}};
    push(@crit_list, $crit) if $crit;


    #attempt to build subs for criteria
    #side-step failure condition compexity with blanket eval
    my $last_crit = '';
    eval {
        my ($sub, @args);
        foreach my $map (@crit_list) {
            foreach (keys(%$map)) {
                $last_crit = $_;

                #lookup handler generator
                ($sub, @args) = $self->resolve_dispatch($_);
                die(sprintf(HANDLER_DIE_MSG, $_,
                    'Handler not found.'))
                    unless ($sub);

                #execute and store sub from generator
                push(@action_list,
                    ((ref($sub) eq '')
                        ? $self->$sub($map->{$_}, @args)
                        : $sub->($self, $map->{$_}, @args)));
            }
        }
        #compile all action subs into single sub
        ($self->{exec_sub} = $self
            ->_compile_exec_sub(@action_list))
    };
    if ($@) {
        chomp($@);
        print("Error: Check if `$last_crit` is valid. ($@)\n");
    }
    return $@ ? 0 : 1;
}


sub resolve_dispatch {

    my ($self, $crit) = @_;
    my $dispatch_tbl = $self->{dispatch_tbl};

    #attempt quick static lookup
    my $sub = $dispatch_tbl->{TYPE_STATIC()}->{$crit};
    return $sub if ($sub);

    #attempt more expensive lookups
    my ($dtype_tbl, @matches, @args);
    RESOLVE_CRIT: foreach (TYPE_CHAINED, TYPE_DYNAMIC) {
        $dtype_tbl = $dispatch_tbl->{$_};
        @matches = reverse(keys(%$dtype_tbl));

        foreach (@matches) {
            next unless (@args = ($crit =~ /$_/));
            $sub = $dtype_tbl->{$_};
            if ($sub) {
                #attempt to retrieve subref if not a method
                $sub = ((exists &$sub) ? \&$sub : $sub)
                    unless (UNIVERSAL::can($self, $sub));
                last RESOLVE_CRIT;
            }
        }
    };
    return ($sub, @args) if ($sub);
}


sub getter { }


sub _compile_exec_sub {
    
    my ($self, @actions) = @_;

    unless ($self->{COMPILE_EXPERIMENTAL}
        and &_load_dds()) {
        #create single multi-action execution sub
        return sub {
    	    my @args = @_;
            foreach (@actions) {
                return 0 unless($_->(@args));
            }
            return 1;
        };
    } else {
        #return experimental flat sub
        return $self->_expr_flatten_subs(@actions);
    }
}

#EXPERIMENTAL
{
    #private vars
    my $ret_stmt = 'return 1;';
    my $ret_repl = 'return 0 unless';
    my $dds_loaded;


    sub _load_dds {
        $dds_loaded //= ((eval('require Data::Dump::Streamer') && !$@) ? 1 : 0);
    }

    #public subs
    sub _expr_flatten_subs {

        my $self = shift;
        my @frags = Data::Dump::Streamer::Dump(@_)->Declare(1)->Dump();
        my @matches;
        foreach (@frags) {
            #NOTE : SUPER FRAGILE, NOT VERY USEFUL
            #       FIND A BETTER WAY!!
            $_ =~ s/(.*[\W])return([\W][^;]*)/$1$ret_repl($2)/g;
            $_ =~ s/(^|\W)my \$CODE[0-9]+ = sub/$1/g;
            $_ =~ s/(^|\W)(use|package)\W[^;]*\;?//g;
        }
        push(@frags, $ret_stmt);
        return eval(join('',
            'sub { ', @frags, ' }'));
    }
}


#CRITERIA FACTORY ROUTINES


sub _gen_is_sub {

    my ($context, $val, $attr) = @_;

    die sprintf(HANDLER_DIE_MSG, 'is',
        'No attribute supplied.')
        unless ($attr);

    return sub {
        return (ref($_[0])
            and (local $_ = getter($_[0], $attr)))
            ? ($_ eq $val)
            : 0;
    };
}


sub _gen_in_sub {

    my ($context, $val, $attr) = @_;

    die sprintf(HANDLER_DIE_MSG, 'is',
        'No attribute supplied.')
        unless ($attr);
    die sprintf(HANDLER_DIE_MSG, 'is',
        'Value supplied must be an ARRAYREF.')
        unless (ref($val) eq 'ARRAY');

    return sub {
        my $ret = 0;
        if (ref($_[0])
            and (my $v = getter($_[0], $attr))) {
            foreach (@$val) {
                ($ret = 1, last) if ($v eq $_);
            }
        }
        return $ret;
    };
}


sub _gen_like_sub {

    my ($context, $val, $attr) = @_;

    die sprintf(HANDLER_DIE_MSG, 'like',
        'No attribute supplied.')
        unless ($attr);

    return sub {
        return (ref($_[0])
            and (local $_ = getter($_[0], $attr)))
            ? m/$val/
            : 0;
    };
}


sub _gen_matches_sub {

    my ($context, $val, $attr) = @_;

    die sprintf(HANDLER_DIE_MSG, 'matches_than',
        'No attribute supplied.')
        unless ($attr);

    return sub {
        (ref($_[0])
            and (local $_ = getter($_[0], $attr)))
            ? ($_ ~~ $val)
            : 0;
    };
}


sub _gen_less_than_sub {

    my ($context, $val, $attr) = @_;

    die sprintf(HANDLER_DIE_MSG, 'less_than',
        'No attribute supplied.')
        unless ($attr);

    return sub {
        (ref($_[0])
            and (local $_ = getter($_[0], $attr)))
            ? ($_ < $val)
            : 0;
    };
}


sub _gen_greater_than_sub {

    my ($context, $val, $attr) = @_;

    die sprintf(HANDLER_DIE_MSG, 'greater_than',
        'No attribute supplied.')
        unless ($attr);

    return sub {
        (ref($_[0])
            and (local $_ = getter($_[0], $attr)))
            ? ($_ > $val)
            : 0;
    };
}





1;
