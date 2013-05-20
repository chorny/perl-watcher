package App::PerlWatcher::Engine;

use 5.12.0;
use strict;
use warnings;

use AnyEvent;
use Data::Dumper;
use Devel::Comments;

sub new {
    my ( $class, $config ) = @_;
    my $watchers = _construct_watchers( $config );
    my $watchers_order = {};
    $watchers_order->{ @{$watchers}[$_] } = $_ for 0 .. @$watchers - 1;
    my $self = {
        _watchers       => $watchers,
        _watchers_order => $watchers_order,
        _statuses       => {},
        _config         => $config // {},
    };
    return bless $self, $class;
}

sub frontend {
    my ( $self, $frontend ) = @_;
    $self->{_frontend} = $frontend;
}

sub config {
    return shift->{_config};
}

sub start {
    my $self     = shift;
    for my $w ( @{ $self->{_watchers} } ) {
        $w->start(
            sub {
                my $status = shift;
                $self->{_statuses}->{ $status->watcher } = $status;

                my $statuses = $self->_gather_results;
                $self->{_frontend}->update($statuses);
            }
        );
    }
    my $loop = $self -> config -> {loop_engine};
    ### $loop
    main $loop;
}

sub _gather_results {
    my $self     = shift;
    my @statuses = sort {
        my $a_index = $self->{_watchers_order}->{ $a->watcher };
        my $b_index = $self->{_watchers_order}->{ $b->watcher };
        return $a_index <=> $b_index;
    } values( %{ $self->{_statuses} } );
    return \@statuses;
}

sub _construct_watchers {
    my $config = shift;
    my @r;
    for my $watcher_definition ( @{ $config -> {watchers} } ) {
         my ($class, $watcher_config ) 
            = @{ $watcher_definition }{ qw/class config/ };
        my $watcher = $class -> new( $config, %$watcher_config );
        push @r, $watcher;
    }
    return \@r;
}

1;
