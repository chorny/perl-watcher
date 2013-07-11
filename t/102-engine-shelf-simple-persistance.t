#!/usr/bin/env perl

use 5.12.0;
use strict;
use warnings;

use Test::More;

use App::PerlWatcher::Engine;
use App::PerlWatcher::Level qw/:levels/;
use App::PerlWatcher::Status;
use App::PerlWatcher::Shelf qw/thaw/;

{
    package Test::PerlWatcher::TestWatcher;
    use base qw/App::PerlWatcher::Watcher/;
    sub new {
        my ( $class, $engine_config, %config ) = @_;
        my $self = $class->SUPER::new($engine_config, %config);
        $self -> _install_thresholds($engine_config, \%config);
        return $self;
    }
    sub description {
        my $self = shift;
        return "$self";
    }
}

my $config = {
    defaults    => {
        timeout     => 1,
        behaviour   => {
            ok  => { 
                1 => 'notice', 
                2 => 'info' 
            },
            fail => { 1 => 'alert' }
        },
    },
    watchers => [
        {
            class => 'Test::PerlWatcher::TestWatcher',
            config => {
                host    =>  '127.0.0.1',
                frequency   =>  1,
            },
        },
    ],
};

my $engine = App::PerlWatcher::Engine->new($config, 'AnyEvent');
ok $engine;

my $watcher = @{ $engine->get_watchers }[0];
ok $watcher;

my $create_status = sub {
    my $level = shift;
    return App::PerlWatcher::Status->new(
        level           => $level,
        watcher         => $watcher,
        description     => sub { $watcher->description },
    );                               
};
                                                   
my $shelf = App::PerlWatcher::Shelf->new;
my $s1 = $create_status->(LEVEL_NOTICE);
my $s2 = $create_status->(LEVEL_NOTICE);
$shelf -> stash_status($s1);
ok !$shelf -> status_changed($s2);

my $serialized = $shelf->freeze;

# new engine forces new watcher instances to be created
$engine = App::PerlWatcher::Engine->new($config, 'AnyEvent');
my $thawed_shelf = thaw($serialized, $engine);

ok !$thawed_shelf -> status_changed($s1);
ok !$thawed_shelf -> status_changed($s2);

# change the config -> no wather and event should be restored 
$config->{watchers}[0]{config}{frequency} = 2;
$engine = App::PerlWatcher::Engine->new($config, 'AnyEvent');
$thawed_shelf = thaw($serialized, $engine);
ok $thawed_shelf -> status_changed($s1);
ok $thawed_shelf -> status_changed($s2);

done_testing();
