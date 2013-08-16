#!/usr/bin/env perl

use 5.12.0;
use strict;
use warnings;

use AnyEvent;
use AnyEvent::HTTPD;
use Devel::Comments;
use File::Basename;
use Path::Class;
use Test::More;

use App::PerlWatcher::Levels;
use aliased 'App::PerlWatcher::Shelf';
use App::PerlWatcher::Status;
use App::PerlWatcher::Watcher::Rss;

sub getRss {
    my $file = file(dirname(__FILE__) . "/data/opennet.ru.rss");
    return scalar $file->slurp;
}

my $server;
my $shelf = Shelf->new;

my $end_var = AnyEvent->condvar;

my $scenario = [
    #1 
    {
        req =>  sub { return getRss(); },
        res =>  sub {
            my $status = shift;
            is $status->level, LEVEL_NOTICE;
            my $items = $status->items->();
            is @{ $items }, 2, "got 2 items (#1)";
            ok $_->does('App::PerlWatcher::Openable') && $_->url, "EventItem is openable"
                for (@{ $items });
            $shelf->stash_status($status);
        },
    },
    
    #2 
    {
        req =>  sub { return getRss(); },
        res =>  sub {
            my $status = shift;
            is $status->level, LEVEL_NOTICE;
            my $items = $status->items->();
            is @{ $items }, 2, "got 2 items (#2)";
            ok $_->does('App::PerlWatcher::Openable') && $_->url, "EventItem is openable"
                for (@{ $items });
            ok !$shelf -> status_changed($status);
            $server = undef;
            $end_var->send;
        },
    },
    
    
];

my ($server_invocations, $callback_invocations) = (0, 0);
my $server_handler = sub {
    return $scenario->[$server_invocations++]->{req}->();
};
my $callback_handler = sub {
    return $scenario->[$callback_invocations++]->{res}->(@_);
};

$server = AnyEvent::HTTPD->new;
$server->reg_cb (
    '/rss1' => sub {
        my ($httpd, $req) = @_;
        $req->respond (
            { content => 
                [
                    'text/html',
                    $server_handler->()
                ]
            },
        );
    },
);
                               
ok defined($server), "served defined";
my $rss_url1 = "http://" . $server->host . ":" . $server->port . "/rss1";

my $engine_config = {
    defaults    => {
        behaviour   => {
            fail => { 
                3   =>  'info',
                5   =>  'alert',
            },
            ok  => { 3 => 'notice' },
        },
    },
};

my $watcher = App::PerlWatcher::Watcher::Rss->new(
    url         => $rss_url1, 
    items_number=> 2, 
    frequency   => 1, 
    timeout     => 1, 
    title       => 'la-la-title',
    on          => { fail => { 2 => 'info' } },
    engine_config => $engine_config
);

ok defined($watcher), "watcher was created";
like $watcher->description, qr/la-la-title/, "check watcher title";

$watcher->start($callback_handler);
$end_var->recv;

is $server_invocations, scalar (grep { $_->{req} } @$scenario), "correct number of server invocations";
is $callback_invocations, scalar (grep { $_->{res} } @$scenario), "correct number of callback invocations";

done_testing();
