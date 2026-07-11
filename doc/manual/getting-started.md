# Getting Started

Starting a sample installation of Tclwire is very simple. You can have a list of the command line options
supported by the server entry point in the customary way for CLI Unix scripts and programs

``` sh
tcl/tclwire.tcl --help
Usage: tclsh tcl/tclwire.tcl ?options?

Options:
  --help
      Show this help message.
  --config <path>     Default: . (no configuration file)
  --host <address>
      Bind address prepared for future services. Default: 127.0.0.1
  --startservers <list>
      Comma-separated protocols to prepare, or 'all'.
  --httpport <port>   Default: 8990
  --httpsport <port>  Default: 9443
  --ftpport <port>    Default: 8991
  --ftpsport <port>   Default: 990
  --proxyport <port>  Default: 8992
  --service <protocol:port>
      Add a service. TLS overrides may follow as
      ';certfile=<path>;keyfile=<path>;upload_area=<path>'.
  --docroot <path>
  --upload-area <path>
      Store HTTP multipart file parts in this directory.
  --max-request-bytes <count>
      Maximum buffered HTTP request size. Default: 16777216
  --request-memory-threshold <count>
      Spool larger HTTP request bodies to disk. Default: 1048576
  --dump-multipart-requests
      Dump complete multipart HTTP requests to stderr. Default: off
  --ftproot <path>
  --certfile <path>
  --keyfile <path>
  --noftp-user-check
  --logfile <path>    Access log. Default: /tmp/tclwire.log
  --logerr <path>     Error log. Default: /tmp/tclwire-err.log
  --log-level <level> Global logging threshold. Default: info
  --conn-max-wait <ms>
      Maximum accepted-socket wait for a connection worker. Default: 1000
  --conn-max-workers <count>
      Maximum connection-agent workers per service. Default: 100
  --conn-max-per-thread <count>
      Maximum connections per connection-agent worker. Default: 5
  --unix-socket <path> Console socket. Default: /tmp/tclwire.sock
  --quiet
  --debug
```

## Scope

- Runtime requirements.
- Running TclWire from the repository.
- Starting a minimal HTTP listener.
- Sending a first HTTP request.
- Reading access and error logs.
- Stopping the server.

## Draft Notes

The initial draft should verify the exact command line against the current
entry point in `tcl/tclwire.tcl` and the sample configuration in
`tclwire.toml.example`.

## Source Material

- `README.md`
- `tclwire.toml.example`
- `tcl/tclwire.tcl`
- `runtime-doc/CONFIGURATION_OPTIONS.md`
