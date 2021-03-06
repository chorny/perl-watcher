package App::PerlWatcher::Watcher;
# ABSTRACT: Observes some external source of events and emits the result of polling them

use 5.12.0;
use strict;
use warnings;

use App::PerlWatcher::Levels;
use App::PerlWatcher::Status;
use aliased 'App::PerlWatcher::WatcherMemory';
use Carp;
use Data::Dump::Filtered qw/dump_filtered/;
use Smart::Comments -ENV;
use Digest::MD5 qw(md5_base64);
use List::Util qw( max );
use Storable qw/freeze/;

use Moo::Role;

with qw/App::PerlWatcher::Describable/;

=attr engine_config

Holds an reference to engine config (used in construction watcher's thresholds_map)

=cut

has 'engine_config'     => ( is => 'ro', required => 1);

=attr init_args

Remembers the arguments for watcher construction (used in construction watcher's
thresholds_map and unique_id)

=cut

has 'init_args'         => ( is => 'rw');

=attr config

The wacher configuration hash ref.

=cut

has 'config'            => ( is => 'lazy');

=attr unique_id

Represents watchers unique_id, calculated from concrete watcher class and
watcher's config. The unique_id is overloaded "to-string" operation, so
watcher can be used to as hash key. unique_id is also used when the
PerlWatcher state is been persisted : the watcher itself isn't stored, but
it's unique_id is stored. That guarantees that unique_id is the same between
PerlWatcher invokations (that's why the perl internal hash funciton isn't used)

=cut

has 'unique_id'         => ( is => 'lazy');

=attr memory

Stores current wacher state (memory). When the watcher is persisted, only it's memory
and unique_id are stored.

=cut

has 'memory'            => ( is => 'rw');

=attr callback

The subroutine reference, which is been called on every poll of watcher external source.
It's argument is the State.

=cut

has 'callback'          => ( is => 'rw', required => 1);

=attr watcher_guard

The watcher guard returned by AnyEvent->io, AnyEvent->timer etc, with is an core
under wich the Watcher is been build.

=cut

has 'watcher_guard'     => ( is => 'rw');

=method build_watcher_guard

The method is responsible for building watcher_guard

=cut

requires 'build_watcher_guard';

use overload fallback => 1, q/""/ => sub { $_[0]->unique_id; };

sub BUILD {
    my ($self, $init_args) = @_;
    $self->init_args($init_args);
    $self->memory($self->_build_memory);
}

sub _build_config {
    my $self = shift;
    my @clean_init_keys =
        grep {$_ ne 'engine_config'}
        keys %{ $self->init_args };
    my %config;
    @config{ @clean_init_keys} = @{ $self->init_args }{ @clean_init_keys };
    return \%config;
}

sub _build_memory {
    my $self = shift;
    my ( $l, $r ) = (
        $self->config        -> {on} // {},
        $self->engine_config -> {defaults}->{behaviour},
    );
    my $map = calculate_threshods($l, $r);
    return WatcherMemory->new(thresholds_map=>$map);
}

sub _build_unique_id {
    my $self = shift;
    my $class = ref($self);
    # Filter strips down the subroutine references
    # and transforms hashes to arrays sorted by keys.
    # this is needed to always have the same string
    # for the same config, any change will lead
    # to change of md5, and the id will be different.
    my $filter; $filter = sub {
        my($ctx, $object_ref) = @_;
        my $ref_type = ref($object_ref);
        return { object => 'FILTERED' } if ($ref_type eq 'CODE');
        return undef                    if ($ref_type ne 'HASH');
        my @determined_array =
            map {
                my $stringized_value = dump_filtered($object_ref->{$_}, $filter);
                my $value = eval $stringized_value;
                ($_ => $value);
            } sort keys %$object_ref;
        return { dump => dump_filtered(\@determined_array, $filter) };
    };
    my $dumped_config = dump_filtered($self->config, $filter);
    my $hash = md5_base64($dumped_config);
    my $id = "$class/$hash";
}

=method force_poll

Immediatly polls the watched object.

=cut

sub force_poll {
    my $self = shift;
    $self->active(0);
    $self->active(1);
}

=method active

Turns on and off the wacher.

=cut

sub active {
    my ( $self, $value ) = @_;
    if ( defined($value) ) {
        $self->memory->active($value);
        $self->watcher_guard(undef)
            unless $value;
        $self->start if $value;
    }
    return $self->memory->active;
}

=method start

Starts the watcher, which will emit it's statuses. The watcher will
start only it is active.

=cut

sub start {
    my $self = shift;
    $self->watcher_guard( $self->build_watcher_guard )
        if $self->memory->active;
}


=method calculate_threshods

Calculates the thresholds_map based on the left map and righ map
The left map has precedence. Usualy the left map is the watchers
config, while the righ map is the generic PerlWatcher/Engine config

=cut

sub calculate_threshods {
    my ($l, $r) = @_;
    my $thresholds_map;
    for my $k ('ok', 'fail') {
        my $merged = _merge($l->{$k}, $r->{$k});
        # from human strings to numbers
        while (my ($key, $value) = each %$merged ){
            $merged->{$key} = get_by_description($value);
        }
        $thresholds_map->{$k} = $merged;
    }
    return $thresholds_map;
}

#
# protected methods
#

sub _merge {
    my ($l, $r) = @_;

    my $max_re = qr/(.*)\/max/;
    my $level = sub {
        my $a = shift;
        return ($a =~ /$max_re/) ? $1 : $a;
    };
    my $wrap = sub {
        my $hash_ref = shift;
        my %cleaned = map { $_ => ( $level->($hash_ref->{$_}) ) }
            keys %$hash_ref;
        ## %cleaned
        my %level_for = reverse %cleaned;
        my @levels = keys %level_for;
        ## @levels;
        my @prepared_result =
            sort { $a->{weight} <=> $b->{weight} }
            map {
                    my $value = $level_for{$_};
                    my $max = $hash_ref->{ $value } =~ /$max_re/;
                    {
                        level   => $_,
                        value   => $value,
                        weight  => get_by_description($_)->value,
                        max     => $max,
                    };
            } @levels;
        return @prepared_result;
    };

    # prepare/wrap left part
    my @l_result = $wrap->($l);
    ## @l_result
    my $max_weight = max
        map { $_->{weight} }
        grep { $_->{max} } @l_result;
    my %l_value_of = map { $_->{level} => $_ } @l_result;

    # join with right part (if there was no key in left)
    my @r_result =
        grep { $max_weight ? ($_->{weight} <= $max_weight) : 1 }
        grep { !exists $l_value_of{ $_->{level} }  }
        $wrap->($r);
    push @l_result, $_ for ( @r_result );
    ## @l_result

    # unwrap
    return { map { $_->{value} => $_->{level} } @l_result };
}

=method interpret_result

This method interprets the result of poll (true or false)
in accordance with thresholds_map and the callback will
be called with the resulting status (and optionally provided
items). Meant to be called from subclases, e.g.

 $watcher->interpret_result(0, $callback);

=cut

sub interpret_result {
    my ($self, $result, $callback, $items) = @_;

    my $level = $self->memory->interpret_result($result);

    $self->_emit_event($level, $callback, $items);
}

sub _emit_event {
    my ($self, $level, $callback, $items) = @_;
    my $status = App::PerlWatcher::Status->new(
        watcher     => $self,
        level       => $level,
        description => sub { $self->describe },
        items       => $items,
    );
    $callback->($status);
}

# storable-methods
sub STORABLE_freeze {
    "$_[0]";
};

sub STORABLE_attach {
    my ($class, $cloning, $serialized) = @_;
    my $id = $serialized;
    my $w = $App::PerlWatcher::Util::Storable::Watchers_Pool{$id};

    # we are forced to return dummy App::PerlWatcher::Watcher
    # it will be filtered later
    unless($w){
       $w = { _unique_id => 'dummy-id'};
       bless $w => $class;
    }
    return $w;
}

1;
