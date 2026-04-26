# NAME

Net::Async::MCP::Server - Async MCP (Model Context Protocol) server using IO::Async

# VERSION

0.001

# SYNOPSIS

    use IO::Async::Loop;
    use Net::Async::MCP::Server;
    use Net::Async::MCP::Server::Transport::Stdio;

    my $loop = IO::Async::Loop->new;

    my $server = Net::Async::MCP::Server->new(
        name => 'my-server',
    );

    $loop->add($server);

    Net::Async::MCP::Server::Transport::Stdio->new(
        server => $server,
    )->handle_requests;

# DESCRIPTION

**Net::Async::MCP::Server** is an asynchronous MCP (Model Context Protocol) server
built on [IO::Async](https://metacpan.org/pod/IO::Async). It handles the MCP protocol handshake
and request routing, allowing subclasses to implement specific tools.

## MCP Protocol

The Model Context Protocol is a JSON-RPC 2.0 based protocol for communication between
AI clients and servers. This implementation supports:

- **initialize** - Protocol handshake and capability negotiation
- **tools/list** - List available tools
- **tools/call** - Execute a tool by name
- **ping** - Keepalive/health check
- **notifications/initialized** - Client ready notification

## Architecture

The server is built on [IO::Async::Notifier](https://metacpan.org/pod/IO::Async::Notifier) for non-blocking
I/O and uses [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait) for clean async/await syntax.

# METHODS

## name

    my $name = $server->name;

Returns the server name exposed via MCP protocol. Default is `'NetAsyncMCPServer'`.

## server\_info

    my $info = $server->server_info;
    # { name => 'my-server', version => '0.001' }

Returns a hashref with `name` and `version` keys for the MCP protocol.

## server\_capabilities

    my $caps = $server->server_capabilities;

Returns the server capabilities hashref.

## initialize

    my $result = $server->initialize->get;

Performs MCP server initialization. Handles the `initialize` request from the client,
returns server info and capabilities.

## register\_tool

    $server->register_tool(
        name        => 'echo',
        description => 'Echoes the input back',
        input_schema => {
            type       => 'object',
            properties => {
                value => { type => 'string' }
            },
            required   => ['value'],
        },
        code => sub {
            my ($args) = @_;
            return { echoed => $args->{value} };
        },
    );

Registers a tool. Expects `name`, `description`, `input_schema`, and `code`.

## tools

    my $tools = $server->tools;

Returns ArrayRef of registered tool definitions.

## list\_tools

    my $tools = $server->list_tools->get;

Returns ArrayRef of tool definitions via Future.

## call\_tool

    my $result = $server->call_tool($name, $arguments)->get;

Called when a client invokes a tool. Looks up the tool by name and executes its code.

# TRANSPORTS

## Net::Async::MCP::Server::Transport::Stdio

Stdio transport for MCP server using newline-delimited JSON-RPC over stdin/stdout.

    use Net::Async::MCP::Server::Transport::Stdio;

    my $transport = Net::Async::MCP::Server::Transport::Stdio->new(
        server => $server,
    );
    $transport->handle_requests;

Each line is a JSON-RPC 2.0 message. Requests are read from stdin, responses written
to stdout.

# SEE ALSO

- [IO::Async::Notifier](https://metacpan.org/pod/IO::Async::Notifier)
- [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait)
- [Net::Async::MCP::Server::Transport::Stdio](https://metacpan.org/pod/Net::Async::MCP::Server::Transport::Stdio)

# AUTHOR

Torsten Raudssus `<getty@cpan.org>`

# COPYRIGHT & LICENSE

Copyright 2026 Torsten Raudssus.

This program is free software; you can redistribute it and/or modify it
under the terms of the Artistic License version 2.0.

See [https://raudss.us.devel](https://raudss.us.devel) for the full license text.
