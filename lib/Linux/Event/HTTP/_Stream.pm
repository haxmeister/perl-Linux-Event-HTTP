package Linux::Event::HTTP::_Stream;
use v5.36;
use parent 'Linux::Event::HTTP::_Transport';
sub on_data ($self, $bytes) {
    my $engine = $self->{http_engine};
    $engine->input($bytes) if $engine && $engine->want_read;
    return;
}
1;
