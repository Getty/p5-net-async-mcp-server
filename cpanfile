requires 'Future', '0.49';
requires 'Future::AsyncAwait', '0.66';
requires 'HTTP::Server::PSGI';
requires 'IO::Async', '0.78';
# JSON::MaybeXS::true/false, which the results are built with, are 1.004+
requires 'JSON::MaybeXS', '1.004';
requires 'Net::Async::HTTP::Server::PSGI', '0.15';

# Streamable HTTP transport
requires 'Plack', '1.0';

on test => sub {
  requires 'HTTP::Request::Common';
  requires 'Plack::Test';
  requires 'Test2::V0';
};

on develop => sub {
  requires 'Dist::Zilla';
};