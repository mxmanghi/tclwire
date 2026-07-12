# Getting Started

Starting an instance of Tclwire is very simple. You can have a list of the command line options
supported by the server entry point in the customary way for CLI Unix scripts and programs. Tclwire has
a configuration file written in TOML format but for many simple cases or for testing purposes the
application server can be run and configured from the command line using these options

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
| --service <protocol:port> | Add a service. TLS overrides may follow as ';certfile=<path>;keyfile=<path>;upload_area=<path>' |
| --docroot <path>    | --upload-area <path> Store HTTP multipart file parts in this directory |
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

Example (assuming your `tclwire.tcl` file is within the shell path):
``` sh
tclwire.tcl --docroot /tmp/tclwire --ftproot /tmp/tclwire --startservers http,ftp
```

Since `/tmp/tclwire` is likely not existing Tclwire will create it and seed it with
some technical documents and the manual. You may check the server by visiting `http://localhost:8990/` 
with you browser.

We told Tclwire to start also the ftp server and have its root directory in the http document
root directory. 

``` sh
> ftp -P 8991 localhost
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
In the current implementation the ftp service doesn't enforce a user check, so it's best
for internal usage to private networks only.

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
