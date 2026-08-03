# Repository Guidelines

## Project Structure & Module Organization

TclWire is a Tcl/TclOO application server. Runtime source lives in `tcl/`, with `tcl/tclwire.tcl` as the executable entry point and package bootstrap. Environment adapters are in `environments/`, reusable helper scripts are in `utils/`, and example applications or protocol fixtures are in `examples/`. Tests live in `tests/` and are organized as `*.test` files driven by `tests/runtests.tcl`. MkDocs documentation is under `doc/`; older runtime-facing documentation and image assets remain in `runtime-doc/`. Legacy implementations and design notes are kept in `legacy/` for reference, not as the primary development target.

## Build, Test, and Development Commands

- `tclsh tests/runtests.tcl`: run the full Tcl test suite with `tcltest`.
- `tclsh tests/runtests.tcl -file application.test`: run one test file while iterating.
- `tclsh tcl/tclwire.tcl <config-file>`: start the runtime from a TOML configuration, for example one derived from `tclwire.toml.example`.
- `mkdocs serve`: preview the manual locally from `doc/`.
- `mkdocs build`: build the static documentation site and catch navigation or Markdown issues.

## Coding Style & Naming Conventions

Use idiomatic Tcl with 4-space indentation inside procedures, methods, conditionals, and test bodies. Keep package declarations explicit and update `pkgIndex.tcl` when adding loadable modules. Public runtime packages follow `tclwire::<area>` names, TclOO classes generally use `::tclwire::C...` or descriptive domain names, and tests use names like `component-1.1` with a short behavior description. Prefer dictionaries for structured data and `try/finally` cleanup for objects, channels, and threads.

## Testing Guidelines

Tests use `tcltest`. Add new coverage in `tests/*.test`, import `::tcltest::*`, append the repository root to `auto_path`, and require only the packages under test. Keep assertions deterministic and clean up objects, channels, files, and threads in `finally` blocks. Run the full suite before submitting changes that touch shared runtime, protocol, or threading code.

## Commit & Pull Request Guidelines

Recent commits use concise, imperative summaries such as `add ChildInitScript and ChildExitScript handling in environment rivet`. Keep commit subjects focused on the behavior changed. Pull requests should describe the user-visible or runtime impact, list tests run, link related issues or design notes, and include screenshots only for documentation or asset changes that affect rendered pages.

## Security & Configuration Tips

Do not commit local runtime configs, secrets, generated logs, or socket paths. Treat `tclwire.toml.example` as the safe template and document any new configuration keys in both `doc/manual/configuration.md` and relevant runtime docs.
