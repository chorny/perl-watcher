package App::PerlWatcher::Watcher::HTTPSimple;
# ABSTRACT: The simple HTTP watcher, where actual http responce body is been processed by closure

use 5.12.0;
use strict;
use warnings;

use App::PerlWatcher::EventItem;
use Carp;
use Devel::Comments;
use Moo;
use URI;

=attr url

The url been wached

=cut

has 'url'                   => ( is => 'ro', required => 1);

=attr response_handler

The callback, which is been called as response_handler($body), and
which should return the body to be displayed as result.

=cut

has 'response_handler'      => ( is => 'ro', required => 1);

=attr processed_response

The last result, which is been stored after invocation of response_handler

=cut

has 'processed_response'    => ( is => 'rw');

with qw/App::PerlWatcher::Watcher::HTTP/;

sub description {
    my $self = shift;
    my $desc = "HTTP [" . $self->title . "]";
    my $response = $self->processed_response;
    $desc .= " : " . ( $response // q{} );
    return $desc;
}

sub process_http_response {
    my ($self, $content, $headers) = @_;
    my ($result, $success) = (undef, 0);

    eval {
        $result = $self->response_handler->(local $_ = $content);
        $success = 1;
    };
    $result = $@ if($@);

    # $result
    # $success
    $self->processed_response($result);
    $self->interpret_result($success, $self->callback);
}

1;
