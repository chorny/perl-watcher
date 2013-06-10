#!/usr/bin/env perl

use 5.12.0;
use strict;
use warnings;

use AnyEvent;
use Gtk2;
use Devel::Comments;
use IO::Socket::INET;
use File::Basename;
use FindBin;
use Test::More;
use Test::TCP;

BEGIN { unshift @INC, "$FindBin::Bin/../lib" }
use App::PerlWatcher::Status qw/:levels/;
use App::PerlWatcher::Shelf;
use App::PerlWatcher::Engine;
use App::PerlWatcher::Frontend;

# watcher event registration
my $server = Test::TCP->new(
  code => sub {
    my $port = shift;
    my $socket = IO::Socket::INET->new(
        LocalPort => $port,
        LocalHost => '127.0.0.1',
        Proto => 'tcp',
        Listen => 1,
    ) or croak ("ERROR in Socket Creation : $!");
    while(1) {
        my $client_socket = $socket->accept();
        $client_socket->close();
    }
  },
);

my $engine;
my $shelf = App::PerlWatcher::Shelf->new;

my $scenario = [
    #1 
    {
        res =>  sub {
            my $status = shift;
            is $status->level, LEVEL_NOTICE;
            ok $shelf -> status_changed($status); 
            ok !$shelf -> stash_status($status);
            ok !$shelf -> status_changed($status);
        },
    },
    
    #2 
    {
        res =>  sub {
            my $status = shift;
            is $status->level, LEVEL_INFO;
            ok $shelf -> status_changed($status); 
            $server = undef;
        },
    },
    
    #3 
    {
        res =>  sub {
            my $status = shift;
            is $status->level, LEVEL_ALERT;
            ok $shelf -> status_changed($status); 
        },
    },
];

my $callback_invocations = 0;
my $callback_handler = sub {
    return $scenario->[$callback_invocations++]->{res}->(@_);
};

{
    package Test::PerlWatcher::FrontEnd;
    use base qw/App::PerlWatcher::Frontend/;
    sub update {
        my ( $self, $status ) = @_;
        $callback_handler->($status);
    }
}
my $frontend = Test::PerlWatcher::FrontEnd->new($engine);

my $config = {
    backend => 'Gtk2',
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
            class => 'App::PerlWatcher::Watcher::Ping',
            config => {
                host    =>  '127.0.0.1',
                port    =>  $server->port,
                frequency   =>  1,
            },
        },
    ],
};
$engine = App::PerlWatcher::Engine->new($config);
ok $engine;
$engine->frontend($frontend);

my $end_var = AnyEvent->condvar;
my $w = AnyEvent->timer (
    after => 2.1,
    cb => sub {
        $engine->stop;
    }
);
$engine->start;

is $callback_invocations, scalar @$scenario, "correct number of callback invocations";

done_testing();
