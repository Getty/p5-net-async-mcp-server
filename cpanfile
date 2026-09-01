requires 'IO::Async', '>= 0.78';
requires 'Future', '>= 0.49';
requires 'Future::AsyncAwait', '>= 0.66';
requires 'JSON::MaybeXS';

# Streamable HTTP transport
requires 'Plack', '>= 1.0';
requires 'HTTP::Server::PSGI';

on test => sub {
  requires 'Test2::V0';
  requires 'Plack::Test';
  requires 'HTTP::Request::Common';
};

on develop => sub {
  requires 'Dist::Zilla';
};