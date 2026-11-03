#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use Net::Async::MCP::Server;

sub _req {
    my ( $method, %extra ) = @_;
    return {
        jsonrpc => '2.0',
        id      => 1,
        method  => $method,
        params  => {
            _meta => {
                'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities' => {},
            },
            %extra,
        },
    };
}

sub _server {
    my (%args) = @_;
    my $s = Net::Async::MCP::Server->new(%args);
    for my $n ( 1 .. 5 ) {
        $s->register_tool( name => "t$n", description => 'd', inputSchema => { type => 'object' } );
        $s->register_resource( uri => "file:///r$n", name => "r$n" );
        $s->register_prompt( name => "p$n", description => 'd' );
    }
    return $s;
}

my %key = ( 'tools/list' => 'tools', 'resources/list' => 'resources', 'prompts/list' => 'prompts' );

subtest 'default: one complete page, no nextCursor' => sub {
    my $s = _server();
    for my $m ( sort keys %key ) {
        my $r = $s->handle( _req($m) )->{result};
        is( scalar @{ $r->{ $key{$m} } }, 5, "$m returns all" );
        ok( !exists $r->{nextCursor}, "$m has no nextCursor" );
    }
};

subtest 'page_size walks all pages via nextCursor' => sub {
    my $s = _server( page_size => 2 );
    is( $s->page_size, 2, 'page_size accessor' );
    for my $m ( sort keys %key ) {
        my ( @seen, $cursor );
        my $pages = 0;
        do {
            my $r = $s->handle( _req( $m, defined $cursor ? ( cursor => $cursor ) : () ) )->{result};
            push @seen, @{ $r->{ $key{$m} } };
            $cursor = $r->{nextCursor};
            $pages++;
        } while ( defined $cursor && $pages < 10 );
        is( $pages, 3, "$m: 3 pages" );
        is( scalar @seen, 5, "$m: 5 items in total" );
        my %uniq = map { ( $_->{name} => 1 ) } @seen;
        is( scalar keys %uniq, 5, "$m: no duplicates" );
    }
};

subtest 'last page exactly full has no nextCursor' => sub {
    my $s = _server( page_size => 5 );
    my $r = $s->handle( _req('tools/list') )->{result};
    is( scalar @{ $r->{tools} }, 5 );
    ok( !exists $r->{nextCursor}, 'no nextCursor' );
};

subtest 'invalid cursor is -32602' => sub {
    my $s = _server( page_size => 2 );
    for my $bad ( 'garbage!', 'AAAA', '' ) {
        my $r = $s->handle( _req( 'tools/list', cursor => $bad ) );
        is( $r->{error}{code}, -32602, "cursor '$bad' rejected" );
        is( $r->{id}, 1, 'id kept' );
    }
    my $r = $s->handle( _req( 'tools/list', cursor => [] ) );
    is( $r->{error}{code}, -32602, 'non-string cursor rejected' );
};

done_testing;
