# Getting Started

After a fresh download of Tclwire starting an instance of Tclwire is very simple. 
(assuming your running `tclwire.tcl` from within the source root):
``` sh
tcl/tclwire.tcl
```

The default document root (`docroot`) is /tmp/tclwire and since it's likely
not existing Tclwire will create it and seed it with some technical documents and
this manual, just to give it a purpose and have in it something for you to see.
Had the directory been existing (even though an empty one) it would be considered
your deliberate act to have it preserved and nothing is copied into it (you can force
the documentation to be copied with the CLI option `--force-docroot-seeding`).
You may check the just created docroot content by visiting the URL `http://localhost:8990/`

Tclwire supports out of the box also 2 more services: FTB and PROXY. You can fire
the ftp service with the command
```sh
tcl/tclwire.tcl --startservers http,ftp
```

Unless you use the `--ftproot` Tclwire assumes the ftp root to be the docroot. The
content can be checked with any ftp client (the default ftp port is 8991)

``` sh
% ftp -P 8991 localhost
Connected to localhost.
220 TclWire FTP server ready
Name (localhost:xxxxx): 
331 User name ok, send password
Password: 
230 Login successful
Remote system type is UNIX.
Using binary mode to transfer files.
ftp> dir
229 Entering Extended Passive Mode (|||40763|)
150 Opening data connection
-rw-r--r-- 1 owner group    26048 Jul 12 12:11 agent_data_structures.html
-rw-r--r-- 1 owner group    16125 Jun 19 11:56 android-chrome-192x192.png
-rw-r--r-- 1 owner group    94261 Jun 19 11:56 android-chrome-512x512.png
-rw-r--r-- 1 owner group    14503 Jun 19 11:56 apple-touch-icon.png
-rw-r--r-- 1 owner group    19172 Jul 12 12:11 configuration_options.html
-rw-r--r-- 1 owner group    11956 Jul 12 12:11 console.html
-rw-r--r-- 1 owner group      508 Jun 19 11:56 favicon-16x16.png
-rw-r--r-- 1 owner group     1167 Jun 19 11:56 favicon-32x32.png
-rw-r--r-- 1 owner group    15406 Jun 19 11:56 favicon.ico
-rw-r--r-- 1 owner group    16138 Jul 12 12:11 functional_components_terminology.html
-rw-r--r-- 1 owner group     9535 Jul 12 12:11 index.html
-rw-r--r-- 1 owner group    27614 Jul 12 12:11 inter_thread_communication.html
-rw-r--r-- 1 owner group    20745 Jul 12 12:11 large_request_data_handling.html
drwxr-xr-x 1 owner group        0 Jul 12 15:14 manual
-rw-r--r-- 1 owner group    16421 Jul 12 12:11 request_body_handling.html
-rw-r--r-- 1 owner group      263 Jun 19 11:56 site.webmanifest
drwxr-xr-x 1 owner group        0 Jul 12 12:11 tcl
-rw-r--r-- 1 owner group    19698 Jun 11 12:41 tcl9.png
-rw-r--r-- 1 owner group    11437 Jun 19 12:19 tclwire-logo-blue.png
-rw-r--r-- 1 owner group    25360 Jun 19 12:19 tclwire-logo-nav.png
-rw-r--r-- 1 owner group    30718 Jun 19 12:19 tclwire-logo.png
-rw-r--r-- 1 owner group     4432 Jul 03 18:17 tclwire.css
-rw-r--r-- 1 owner group    15119 Jul 12 12:11 todo.html
-rw-r--r-- 1 owner group    10558 Jul 12 12:11 wb_dev_status_assessment.html
-rw-r--r-- 1 owner group    42681 Jul 12 12:11 worker_request_api.html
-rw-r--r-- 1 owner group    17773 Jul 12 12:11 workload_balancer.html
```

You can have a list of the command line options supported by the server entry
point in the customary way for CLI Unix scripts and programs. Tclwire has a
configuration file written in TOML format but for many simple cases or for
testing purposes the application server can be run and configured from the
command line using these options

| Option | Description |
|-----------|------------------------------------------------------|
| --help              | Show this help message |
| --config <path>     | Default: . (no configuration file) |
| --host <address>    | Bind address prepared for future services. Default: 127.0.0.1 |
| --startservers <list> | Comma-separated list of protocols (http,https,ftp,ftps,proxy) to start, or 'all' |
| --httpport <port>   | Port for the http service. Default: 8990 |
| --httpsport <port>  | Port for the https service. Default: 9443 |
| --ftpport <port>    | Port for the ftp service. Default: 8991 |
| --ftpsport <port>   | Port for the ftps service. Default: 990 |
| --proxyport <port>  | Port for the proxy service. Default: 8992 |
| --service <protocol:port> | Add a service. TLS overrides may follow as <br/>`;certfile=<path>;keyfile=<path>;upload\_area=<path>` |
| --docroot <path>    | Default docroot for HTTP and FTP services |
| --force-docroot-seeding | Force the Tclwire documents to be copied into a docroot even when it's not emtpy |
| --upload-area <path> | Store HTTP multipart file parts in this directory |
| --max-request-bytes <count> | Maximum buffered HTTP request size. Default: 16777216 |
| --max-header-bytes <count> | Maximum buffered HTTP request header size. Default: 65536 |
| --request-memory-threshold <count> | Spool larger HTTP request bodies to disk. Default: 1048576 |
| --dump-multipart-requests | Dump complete multipart HTTP requests to stderr. Default: off |
| --ftproot <path>  | Default root of the ftp service |
| --certfile <path> | Path to the default TLS certificate for the https or ftps services |
| --keyfile <path>  | Path to the default TLS private key for the https or ftps services |
| --noftp-user-check | Don't check ftp users |
| --logfile <path> | Access log. Default: /tmp/tclwire.log |
| --logerr <path>  | Error log. Default: /tmp/tclwire-err.log |
| --log-level <level> | Global logging threshold. Default: info |
| --conn-max-wait <ms> | Maximum accepted-socket wait for a connection worker. Default: 1000 |
| --conn-max-workers <count> | Maximum connection-agent workers per service. Default: 100 |
| --conn-max-per-thread <count> | Maximum connections per connection-agent worker. Default: 5 |
| --unix-socket <path> | Console socket. Default: /tmp/tclwire.sock |
| --quiet | |
| --debug | |

In the current implementation the ftp service doesn't enforce a user check, so it's best
for usage to private networks only.

## Scope

- Runtime requirements.
- Running TclWire from the repository.
- Starting a minimal HTTP listener.
- Sending a first HTTP request.
- Reading access and error logs.
- Stopping the server.

## Draft Notes

The initial draft should verify the exact command line against the current
entry point in `tcl/tclwire.tcl` and the sample configuration in `tclwire.toml.example`.

## Source Material

- `README.md`
- `tclwire.toml.example`
- `tcl/tclwire.tcl`
- `runtime-doc/CONFIGURATION_OPTIONS.md`
