#!/usr/bin/env perl

#TODO: check validity of fix, write tests, publish
#See https://github.com/jdv/data-selector/issues/1
use lib '.';

use Data::Selector;
use Digest::SHA ();
use File::Temp ();
use JSON::XS ();
use LWP::UserAgent;
use Number::Bytes::Human;
use Plack::Request;
use Time::HiRes ();
use Web::Simple 'Data::Selector::Server';

package Data::Selector::Server;

has stash => ( is => 'rw', );

has link => ( is => 'rw', );

sub default_config { (
    dir => "$ENV{HOME}/.data-selector-server/",
) }

=head1 METHODS

=cut

=over

=item init

Initialize state:

* get link (permalink) from url if its there
* restore stash vars from linked file if it exists or use defaults

=cut

sub init {
    my ( $self, $env, ) = @_;

    my $req = Plack::Request->new( $env );
    my $stash;

    $self->link( $req->path_info =~ s/^.*\///r );
    if ( $self->link ) {
        my $json = do {
            local $/ = undef;
            open( my $fh, '<', $self->config->{dir} . $self->link )
              or die $!;
            <$fh>;
        };
        $stash = JSON::XS::decode_json( $json );
    }

    $stash->{$_} ||= $req->parameters->{$_} || ''
      for qw( selector json_text req_url req_body );

    $stash->{req_do} = keys %{ $req->parameters }
      ? $req->parameters->{req_do} : 'checked';

    $stash->{req_method} ||= $req->parameters->{req_method} || 'GET';

    $stash->{req_body} = JSON::XS->new->pretty->canonical->utf8->encode(
        JSON::XS::decode_json( $stash->{req_body} )
    ) if $stash->{req_body};

    $stash->{source_desc} = $stash->{json_text} ? '(from json in' : '';
    $stash->{data} = '';

    $self->stash( $stash );

    return;
}

sub _gen_rover_auth_headers {
    my ( $self, ) = @_;
    my $now = time;
    my ( $id, $secret, ) = @{ $self->config }{qw(rover_id rover_secret)};
    return $id && $secret && $self->stash->{req_url} =~ /rover/ ? (
        Authorization => "Doorman-SHA256 Credential=$id",
        Timestamp => $now,
        Signature => Digest::SHA::sha256_hex($id, $secret, $now),
    ) : ();
}

=item request

Do request.

=cut

sub request {
    my ( $self, ) = @_;

    my $stash = $self->stash;

    my $req = HTTP::Request->new(
        $stash->{req_method} => $stash->{req_url}, );
    if ( $stash->{req_body} ) {
        $req->add_content_utf8( $stash->{req_body}, );
        $stash->{source_desc} .= ' and request body';
        $req->content_type( 'application/json; charset=utf-8', );
    }
    my $before = Time::HiRes::time;
    my $res = LWP::UserAgent->new( default_headers => HTTP::Headers->new(
        Accept => 'application/json; charset=utf-8',
        $self->_gen_rover_auth_headers,
    ), )->request( $req );
    my $req_time = sprintf('%.2fs', Time::HiRes::time - $before);
    my $len = Number::Bytes::Human::format_bytes(length($res->content)) || 0;

    $stash->{source_desc} = '(from request('
      . join( ',', $res->code, "${len}B", $req_time, ) . ')';

    my $get_json_error = sub {
        # django, really...  Why you mix html and json?
        my $text = $_[0]->decoded_content =~ s/.*<br>//r;
        eval { JSON::XS::decode_json( $text ) } ? $text : undef;
    };

    if ( $res->is_success ) {
        $stash->{json_text} = $res->decoded_content;
    }
    elsif ( my $text = $get_json_error->($res) ) {
        $stash->{json_text} = $text;
        $stash->{is_error}++
    }
    else { die $res->status_line . "\n" . $res->content . "\n"; }

    $self->stash( $stash );

    return;
}

=item produce

Do data selection.

=cut

sub produce {
    my ( $self, ) = @_;

    my $stash = $self->stash;

    $stash->{json_text} = JSON::XS->new->pretty->canonical->utf8->encode(
        $stash->{data} = JSON::XS::decode_json( $stash->{json_text} )
    );

    Data::Selector->apply_tree( {
        selector_tree => Data::Selector->parse_string( {
            selector_string => $stash->{selector},
        } ),
        data_tree => $stash->{data},
    } ) if $stash->{selector};

    $stash->{data} = JSON::XS->new->pretty->canonical->utf8->encode(
      $stash->{data} );

    $self->stash( $stash );

    return;
}

=item persist

Throw stash to permalink's file.

=cut

sub persist {
    my ( $self, ) = @_;

    my ( $fh, $filename ) = File::Temp::tempfile(
        'XXXXXXX', DIR => $self->config->{dir}, );
    print $fh
        JSON::XS->new->pretty->canonical->utf8->encode( $self->stash );
    close $fh or die $!;
    $self->link( $filename =~ s/^.*\///r );

    return;
}

=item render

Kick out html.

=cut

sub render {
    my ( $self, ) = @_;

    my $stash = $self->stash;

    # about 80x25?
    my ( $width, $height, ) = ( "width: 52em;", "height: 31em;", );
    $self->stash->{source_desc} .= ')';

    my $req_method_options;
    for ( qw(GET POST PUT DELETE PATCH) ) {
        $req_method_options .= qq{<option value="$_"};
        $req_method_options .= qq{selected}
          if $stash->{req_method} eq $_;
        $req_method_options .= qq{>$_</option>\n};
    }

    my $out_color = $stash->{is_error} ? 'red' : 'black';

    $stash->{html} = <<"HTML";
        <html>
            <head>
                <title>@{[ref $self]}</title>
            </head>
            <body>
                <form method="post" enctype="multipart/form-data" action="/">
                    <input type="submit" value="submit">

                    <a href="/@{[$self->link]}">permalink</a>

                    summary:
                      (<a href="#json_in">json in</a>
                      |<a href="#request_url">request url</a>
                      [&<a href="#request_body">request body</a>])
                      [+<a href="#selector">selector</a>]
                      =<a href="#json_out">json out</a><br>

                    <label for="selector">
                        <a
                          href="https://metacpan.org/pod/release/JDV/Data-Selector-1.01/lib/Data/Selector.pm#SELECTOR-STRINGS"
                          target="_blank">selector:</a>
                    </label>
                    <input name ="selector" type="text" style="$width"
                      value="$stash->{selector}"><br>

                    <label for="req_url" id ="request_url"
                      >request url:</label>
                    <input name ="req_do" type="checkbox"
                      value="checked" @{[$stash->{req_do}||'']}>
                    <input name ="req_url" type="text" style="$width"
                      value="$stash->{req_url}"><br>

                    <label for="req_method" id ="request_method"
                      >request method:</label>
                    <select name="req_method">
                        $req_method_options
                    </select>

                    <hr>
                        <div id="json_out">
                            json out$stash->{source_desc}:
                            <font color="$out_color">
                                <pre>$stash->{data}</pre>
                            </font>
                        </div>
                    <hr>

                    <label for="json_text" id="json_in">json in:</label>
                    <textarea name="json_text"
                      style="$width $height; color:$out_color"
                      >$stash->{json_text}</textarea><br>

                    <label for="req_body" id="request_body"
                      >request body:</label>
                    <textarea name="req_body" style="$width $height"
                      >$stash->{req_body}</textarea><br>

                    <input type="submit" value="submit">
                </form>
            </body>
        </html>
HTML

    $self->stash( $stash );

    return;
}

=item dispatch_request

The Web::Simple request dispatcher.

=cut

sub dispatch_request {
    'GET | POST + /...' => sub {
        my ( $self, $env, ) = @_;

        eval {
            $self->init( $env, );
            if ( $self->stash->{req_url} ) {
                if ( !$self->{stash}->{req_do} ) {
                    $self->stash->{source_desc}
                      .= '.  request url exists but request skipped'
                      . ' since unchecked.';
                }
                elsif( $self->link ) {
                    $self->stash->{source_desc}
                      .= '.  request url exists but request skipped'
                      . ' since linked.  submit to request.';
                }
                else { $self->request; }
            }

            $self->produce if $self->stash->{json_text};
            $self->persist
              if !$self->link && grep { $_; } values %{ $self->stash };
            $self->render;
        };
        my $error = $@;

        [
            $error ? 500 : 200, [ 'Content-type', 'text/html', ],
            [ $error ? $error =~ s/\n/<br>/r : $self->stash->{html}, ],
        ],
    },
    '' => sub {
        [ 405, [ 'Content-type', 'text/plain', ], [ 'Method not allowed', ], ],
    },
    'GET + /favicon.ico' => sub {
        [ 404, [ 'Content-type', 'text/plain', ], [ 'Not Found', ], ],
    },
}

Data::Selector::Server->run_if_script;
