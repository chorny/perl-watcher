package App::PerlWatcher::Watcher::GenericExecutor;
# ABSTRACT: Watches for the output of execution of arbitrary command.

use 5.12.0;
use strict;
use warnings;

use AnyEvent;
use AnyEvent::Util;
use Smart::Comments -ENV;
use Moo;
use POSIX qw(SIGKILL);

use App::PerlWatcher::Levels qw/get_by_description LEVEL_NOTICE/;
use aliased qw/App::PerlWatcher::EventItem/;
use aliased qw/App::PerlWatcher::Status/;

with qw/App::PerlWatcher::Watcher/;

=head1 SYNOPSIS

 # use the following config for Engine:

    {
        class => 'App::PerlWatcher::Watcher::GenericExecutor',
        config => {
	        command       => "/bin/ls",
	        arguments     => ["-1a", "/tmp/"],
            frequency     => 60,
  	        timeout       => 5,
		    # filtering "." and ".." files
	        filter        => sub { ($_ !~ /^\.{1,2}$/) && (/\S+/) },
	        rules         => [
	  	    # rise warning if strange_file if found among files
		    # don't forget to use List::MoreUtils qw/any/;
		    # in the beggining of the config
            	warn  => sub { any { /strange_file.txt/ } @_ },
	        ],
	    }
     }

=cut

=attr command

The command (executable) regularry been executed, e.g. /bin/ls

=cut

has 'command' => ( is => 'ro', required => 1 );

=attr arguments

The array of arguments, givent to the command, e.g. ["/tmp"].
Default value is an empty array

=cut

has 'arguments' => (is => 'ro', default => sub{ []; } );

=attr frequency

How often the external command will be executed (in seconds).
Default value is 600 seconds (10 mins).

=cut

has 'frequency' => (is => 'ro', defalut => sub{ 600; } );

=attr timeout

The maximum execution time of the command in seconds. Default value
10 seconds.

=cut

has 'timeout' => (is => 'ro', defalut => sub{ []; } );

=attr filter

The closure, which returns true if the current line of command
output should be displayed. Default value: always return true,
which means to dispay all command's output. The current line
is localized to $_ variable.

=cut

has 'filter' => (is => 'ro', default => sub{ sub{ 1; };  } );

=attr beautifyer

The closure which is been applied to each line of filtered
output to add/strip something. Defaut value: just return
the unchanged line

=cut

has 'beautifyer' => (is => 'ro', default => sub{ sub{ shift;}; });

=attr rules

The list, consisting of level and rule of it. If rule returns true
a status with that level will be emitted, and no other rules will
be evaluated.

Each rule is an closure, wich takes an list of output lines, and
returns true if the rule should be applied.

Default value: empty list of rules.

If no is applied, the default status level is 'notice'.

=cut

has 'rules' => (is => 'ro', default => sub { []; });


sub description {
    my $self = shift;
    return "GenericExectuor [" . $self->command . "]";
}

sub _get_level {
    my ($self, @lines) = @_;
    my $rules = $self->rules;
    for (my $i =0; $i < @$rules; $i+=2 ) {
        my $level_string = $rules->[$i];
        my $rule         = $rules->[$i+1];
        return get_by_description($level_string)
            if ($rule->(@lines));
    }
    return LEVEL_NOTICE;
}

=attr callback_proxy

That closure actully processes the output from command
and invokes actual callback with Status and EventItems

=cut

has 'callback_proxy' => (is => 'lazy');

sub _build_callback_proxy {
    my $self = shift;
    return sub {
        my $success = shift;
        unless ($success) {
            my $reason = shift;
            return $self->callback->(
                Status->new(
                    watcher     => $self,
                    level       => LEVEL_NOTICE,
                    description => sub { $self->description . " : $reason" },
                    items       => sub { [] },
                )
            );
        }
        my $output = shift;
        my @lines = split("\n", $output);
        @lines =
            map  {$self->beautifyer->($_)}
            grep { $self->filter->($_) }
            @lines;
        my $level = $self->_get_level(@lines);
        my @items = map {
            EventItem->new(
                content => $_,
            );
        } @lines;
        $self->callback->(
            Status->new(
                watcher     => $self,
                level       => $level,
                description => sub { $self->description; },
                items       => sub { \@items, },
            )
        );
    };
}


sub build_watcher_guard {
    my $self = shift;
    my $guard = AnyEvent->timer(
        after    => 0,
        interval => $self->frequency,
        cb       => sub {
            my $output;
            my $pid;
            my $timeout = $self->timeout;
            my $cv_cmd = run_cmd
                [$self->command, @{ $self->arguments }],
                ">"  => \$output,
                '$$' => \$pid;
            my $timer; $timer = AnyEvent->timer(
                after => $timeout,
                cb    => sub {
                    $output = "timeout($timeout)";
                    $cv_cmd->send(1);
                    undef $cv_cmd;
                    kill SIGKILL, $pid;
                },
            );
            $cv_cmd->cb(
                sub {
                    my $success = !shift->recv;
                    undef $timer;
                    $self->callback_proxy->($success, $output);
                }
            );
        });
    return $guard;
};

1;
