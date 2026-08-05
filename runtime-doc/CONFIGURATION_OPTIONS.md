# Configuration Options

This document summarizes the runtime configuration options that currently
control the TclWire application server. Command-line options override TOML
configuration values, and TOML values override built-in defaults.

Path values in TOML are resolved relative to the configuration file directory.
Path values from the command line are normalized relative to the current
working directory. Boolean TOML values accept Tcl-style boolean spellings such
as `true`, `false`, `yes`, `no`, `on`, `off`, `1`, and `0`.

## Global Options

`--config <path>` / configuration file path
: Loads a TOML configuration file before command-line overrides are applied.
  The default `.` means no configuration file.

`--bind-address <address>` / `--listen-address <address>` / `--host <address>` / `tclwire.bind_address`
: Local address used by every configured service listener. Defaults to
  `127.0.0.1`. `--host`, `tclwire.host`, and `tclwire.listen_address` are
  aliases.

`--startservers <list>`
: Selects the protocols to start from the configured service set. The value is
  a comma-separated list containing `http`, `https`, `ftp`, `ftps`, and/or
  `proxy`, or the special value `all`. The default is `http`. This option has
  no TOML equivalent; protocol TOML tables select services when a config file
  is used.

`--service <protocol:port[;option=value...]>`
: Adds explicit service endpoints. When any `--service` option is present, the
  command-line service list replaces the configured service list. Supported
  protocols are `http`, `https`, `ftp`, `ftps`, and `proxy`.

`--docroot <path>` / `tclwire.docroot`
: Global HTTP application document root. The built-in default is TclWire's
  default document root. If `ftproot` is not set separately, changing
  `docroot` also changes the FTP root.

`--force-docroot-seeding`
: Seeds the generated documentation into `docroot` even when the directory
  already exists. By default, an existing `docroot`, including an empty one, is
  treated as user-managed and is not seeded. This option is command-line only.

`--upload-area <path>` / `tclwire.upload_area`
: Default storage directory for HTTP and HTTPS multipart file parts and
  spooled request bodies. Defaults to `/tmp`. An empty value disables file
  storage for multipart uploads and keeps request bodies in memory up to the
  configured request limit.

`--max-request-bytes <count>` / `tclwire.max_request_bytes`
: Maximum buffered HTTP or HTTPS request size in bytes. Defaults to
  `16777216` and must be at least `1`.

`--max-header-bytes <count>` / `--max_header_bytes <count>` / `tclwire.max_header_bytes`
: Maximum buffered HTTP or HTTPS request header size in bytes. Defaults to
  `65536` and must be at least `1`.

`--request-memory-threshold <count>` / `tclwire.request_memory_threshold`
: Number of request-body bytes kept in memory before the HTTP protocol session
  spools the body to `upload_area`. Defaults to `1048576`. A value of `0`
  spools every non-empty body.

`--dump-multipart-requests` / `tclwire.dump_multipart_requests`
: Writes complete multipart HTTP requests to standard error for diagnostics.
  Disabled by default. This can expose request headers and uploaded content.

`--ftproot <path>` / `tclwire.ftproot`
: FTP and FTPS root directory. Defaults to TclWire's default FTP root, which
  follows `docroot` unless explicitly set.

`--certfile <path>` / `tclwire.certfile`
: Default TLS certificate file for secure services. `https` and `ftps`
  services inherit this value unless they define their own certificate.

`--keyfile <path>` / `tclwire.keyfile`
: Default TLS private key file for secure services. `https` and `ftps`
  services inherit this value unless they define their own key.

`--noftp-user-check` / `tclwire.ftp_user_check`
: Controls FTP and FTPS password checking. The default is enabled. The CLI
  form only disables the check; TOML can set it true or false.

`--logfile <path>` / `tclwire.logfile`
: Access log path. Defaults to `/tmp/tclwire.log`.

`--logerr <path>` / `tclwire.logerr`
: Error log path. Defaults to `/tmp/tclwire-err.log`.

`--log-level <level>` / `tclwire.log_level`
: Global logging threshold. Defaults to `info`. Supported levels are
  `trace8` through `trace1`, `debug`, `info`, `notice`, `warn`, `error`,
  `crit`, `alert`, and `emerg`.

`--conn-max-wait <ms>` / `--conn_max_wait <ms>` / `tclwire.conn_max_wait`
: Maximum time, in milliseconds, an accepted socket waits for a connection
  worker before retry handling applies. Defaults to `1000` and must be
  nonnegative.

`--conn-max-workers <count>` / `--conn_max_workers <count>` / `tclwire.conn_max_workers`
: Maximum connection-agent workers per service endpoint. Defaults to `100` and
  must be at least `1`.

`--conn-max-per-thread <count>` / `--conn_max_per_thread <count>` / `tclwire.conn_max_per_thread`
: Maximum simultaneous accepted connections assigned to one connection-agent
  worker. Defaults to `5` and must be at least `1`.

`--unix-socket <path>` / `tclwire.unix_socket`
: Unix-domain console socket path. Defaults to `/tmp/tclwire.sock`.

`--quiet` / `tclwire.quiet`
: Suppresses normal runtime chatter where components observe the quiet flag.
  Disabled by default.

`--debug` / `tclwire.debug`
: Enables TclWire debug output. Disabled by default.

`tclwire.debug_connection`
: Retains closed connection records and close diagnostics in the shared
  accounting store for console inspection. Disabled by default.

`tclwire.encoding`
: Default application text encoding. Defaults to `utf-8`.

`tclwire.libdir`
: Default directory for application class files and packages. Application
  `docroot` has search precedence, then the effective `libdir`, then the
  TclWire installation.

`tclwire.default_application`
: Application ID selected when an HTTP request has no `Host` header. Defaults
  to `default`.

`tclwire.default_hosts`
: Host header aliases served by the default application when its application
  table omits `hosts`. If omitted, the built-in default application serves
  `localhost 127.0.0.1`, while a renamed default application without explicit
  hosts uses its application ID.

`tclwire.aliases`
: Multiline URL-to-local-path alias rules inherited by HTTP and HTTPS
  applications. Each nonblank line is either `URL-path local-path` or
  `Alias URL-path local-path`. The URL path must begin with `/`. A relative
  local path is resolved under each application's `docroot`; an absolute local
  path is used as-is after normalization.

`--help`
: Prints runtime usage and returns a prepared configuration without starting
  the server.

## Service-Specific Options

Service-specific TOML options live under protocol tables: `[http]`,
`[https]`, `[ftp]`, `[ftps]`, and `[proxy]`.

`enabled`
: Enables or disables the protocol service declared by the table. If omitted,
  the service is enabled when the table exists. If no protocol tables exist in
  a TOML file, no external services are started from that file.

`port`
: Listener port for the protocol service. Defaults are `8990` for `http`,
  `9443` for `https`, `8991` for `ftp`, `990` for `ftps`, and `8992` for
  `proxy`. CLI aliases `--httpport`, `--httpsport`, `--ftpport`,
  `--ftpsport`, and `--proxyport` override these values.

`log_level`
: Service-level logging threshold for the protocol endpoint. Currently
  supported by `http` and `https` TOML tables.

`certfile`
: TLS certificate file for `https` or `ftps`. Overrides `tclwire.certfile` for
  that service.

`keyfile`
: TLS private key file for `https` or `ftps`. Overrides `tclwire.keyfile` for
  that service.

`upload_area`
: HTTP or HTTPS service-specific upload and body-spool directory. Overrides
  `tclwire.upload_area`.

`max_request_bytes`
: HTTP or HTTPS service-specific maximum request size. Overrides
  `tclwire.max_request_bytes`.

`max_header_bytes`
: HTTP or HTTPS service-specific maximum request header size. Overrides
  `tclwire.max_header_bytes`.

`request_memory_threshold`
: HTTP or HTTPS service-specific in-memory request-body threshold. Overrides
  `tclwire.request_memory_threshold`.

`libdir`
: HTTP or HTTPS service default for application `libdir`. It overrides
  `tclwire.libdir` and is overridden by an application-specific `libdir`.

`root`
: FTP or FTPS root directory. Overrides `tclwire.ftproot`.

`user_check`
: FTP or FTPS password-check flag. Overrides `tclwire.ftp_user_check`.

## Custom Service Fields

The `--service` command-line option accepts a base endpoint followed by
semicolon-separated fields, for example:

```sh
--service 'https:9443;certfile=cert.pem;keyfile=key.pem;upload_area=/tmp/uploads'
```

`protocol:port`
: Required service endpoint. The protocol must be one of `http`, `https`,
  `ftp`, `ftps`, or `proxy`; the port must be between `1` and `65535`.

`certfile=<path>`
: Per-endpoint TLS certificate override for secure services.

`keyfile=<path>`
: Per-endpoint TLS private key override for secure services.

`upload_area=<path>`
: Per-endpoint upload and spool directory for HTTP or HTTPS. An empty value
  disables file storage for that endpoint.

## HTTP Application Options

HTTP and HTTPS application options live under application tables such as
`[http.default]`, `[http."example.test"]`, or `[https.admin]`. The final table
component is the application ID. Quote application IDs containing dots so TOML
treats the DNS name as one key, for example `[http."hello.example.test"]`.
Host-specific applications inherit from the configured default application,
then from global runtime defaults.

`class`
: TclOO application class name. Required after inheritance. Bare names are
  qualified under `::tclwire::app`; fully qualified names are left unchanged.

`hosts`
: Host names served by the application. If omitted by the default application
  and `tclwire.default_hosts` is configured, the default application uses
  those aliases. Otherwise, an omitted host table uses the application ID as
  the host name. The current TOML parser expects this as a Tcl list encoded in
  one string.

`docroot`
: Application document root. Inherits from the global `docroot` unless
  overridden.

`aliases`
: Application-specific URL-to-local-path alias rules. The format is the same
  as `tclwire.aliases`. Application rules are searched before inherited rules,
  so they can override a global or default-application prefix and still extend
  the inherited set. TclWire currently supports only simple prefix aliases in
  the style of Apache `mod_alias`: the unmatched URL suffix is appended to the
  target path.

`encoding`
: Application text encoding. Defaults to `tclwire.encoding` and must be known
  to Tcl.

`package`
: Package loaded with `package require` to provide the application class. An
  application must define either `package` or `file` after inheritance.

`file`
: Application source file. Relative values are searched under the application
  `docroot`, effective `libdir`, and TclWire installation. File-backed
  applications are sourced under `::tclwire::app`, so bare class definitions
  become `::tclwire::app::<ClassName>`.

`libdir`
: Application-specific library directory. Overrides service and global
  `libdir` values.

`environment`
: Tcl list of application environments loaded into each CGA worker before
  request-time application instances are created. An environment may also
  provide the application class when `class` is omitted.

`configure`
: Application-owned configuration dictionary. Direct values under
  `[http.<application>.configure]` or `[https.<application>.configure]` apply
  to the resolved application class. Child tables keyed by TclOO class name
  target that class explicitly.

  `::tclwire::CApplication` supports `directory_index`, a space-separated list
  of plain file names searched when a URL maps to a directory. The default is
  `index.html`.

`minimum_workers`
: Minimum number of content-generator workers for the application pool.
  Defaults to `0`.

`maximum_workers`
: Maximum number of content-generator workers for the application pool.
  Defaults to `20` and must not be less than `minimum_workers`.

`log_level`
: Application or host-specific logging threshold.

`reload_on_request`
: Replaces the application worker after each request so the next worker sources
  the current `file`. Disabled by default and valid only when `file` is
  configured.

`retain_uploaded_files`
: Prevents TclWire from deleting stored multipart upload files after request
  processing. Disabled by default and intended only for development or
  explicit handoff workflows.
