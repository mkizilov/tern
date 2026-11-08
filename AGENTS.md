# Tern: project boundaries and working agreement

- Work only in `/Users/mk-rune/test_projects/10-tern`. This is one of fourteen independent repositories.
- Do not read, modify, clean up, or run commands in sibling repositories or the user's configuration.
- Work autonomously: choose sensible defaults and document assumptions; do not ask questions or delegate.
- Never install anything globally or use sudo, Homebrew, launchd, host credentials, or host Docker sockets.
- Dependencies, toolchains, caches, browser binaries, SDKs, temporary files and test data stay in this repository. Preserve the supplied project-local environment. Python packages go in `.venv`.
- `.agent-local/` is ignored, project-local build/runtime state. `.opencode/` is managed orchestration configuration; do not change or remove it or bypass the sandbox.
- Use existing system tools read-only, or install pinned tools under this repository. Do not change shell profiles, user settings, Keychain, or global Git settings.
- Bind test servers to loopback; use ports 21900–21999. Limit build/test workers to two unless a required benchmark explicitly needs more.
- Docker-dependent integration tests must remain reproducible but be reported as unverified here if they require access outside this repository. Do not bypass this boundary.
- Do not touch attached hardware, enroll services, flash firmware, install agents, or alter OS settings. Supply manual checklists for such steps.
- Implement only the current numbered prompt, preserving prior behavior. Run appropriate checks, fix failures, and report genuine limitations without fabricating test or benchmark results.
- Before finishing every numbered turn: stop its servers/watchers, remove scratch outputs, update relevant documentation, and make a local conventional-commit Git commit. Do not push.
- End each turn with a short summary of changes, checks actually run, remaining limitations, and commit hash. The orchestrator will provide the next prompt only after this turn ends.

Extend this file with the project's language-specific architecture and verification commands while retaining these boundaries.

## OCaml architecture and local tools

- `LANGUAGE.md` defines Tern semantics; `DESIGN.md` defines phase contracts.
  The target compiler is `ternc`. Prompt 1 intentionally has no compiler code.
- Implement phases as a reusable OCaml library under `lib/`, the CLI under
  `bin/`, and phase tests under `test/`, when those phases are requested.
  Keep phases separate, with source locations and structured errors.
- OCaml 5.5.2 is selected for the project-local `_opam/` switch. Run
  `scripts/setup.sh` for local opam, dependencies, and pinned wasm-tools.
  Preserve the supplied project-local environment. `DESIGN.md` records host
  prerequisites and the installation limitation observed in turn 1.
- Declare dependencies in `dune-project`; regenerate and commit `ternc.opam`.
  Do not hand-maintain divergent dependency lists. Do not commit toolchains,
  caches, build outputs, or temporary test fixtures.

## Verification commands and tests

- `scripts/check.sh` is the authoritative gate: it prepends `.tools/bin` to PATH,
  selects this repository's switch, and runs `dune build`, `dune test`, then
  `dune fmt`, each with `-j 2`. Missing tools and failed steps are errors.
- With the local opam environment selected, individual commands are
  `dune build -j 2`, `dune test -j 2`, and `dune fmt -j 2`.
- `dune build @fmt --auto-promote` applies formatting. Re-run checks afterward.
  `.ocamlformat` pins the formatter configuration/version.
- Every compiler phase must have `ppx_expect` tests for successful behavior and
  meaningful errors, using stable printers and deterministic variable names.
  Never replace phase tests with CLI-only smoke tests. Add QCheck properties
  where they test real invariants, not as empty scaffolding.
- `python3 tests/test_project.py` runs offline infrastructure checks directly;
  `dune test` also invokes them. These do not execute Tern or validate a toolchain.
- Each `.tern` example has matching `.out` exact stdout. When an interpreter and
  backend exist, run the corpus against both; keep diagnostics separate from
  stdout. Print built-ins do not add newlines automatically.

## Definition of done for future tasks

1. Implement only requested behavior, with new tests (including phase
   `ppx_expect` tests) and appropriate regression/property checks.
2. Update relevant language/design/usage documentation alongside behavior.
3. Run `scripts/check.sh` successfully and fix available failures. If a real
   environment boundary blocks it, report the command and observed error, name
   unverified checks, and never claim the gate passed.
4. Stop task processes and remove scratch resources, preserving user work and
   local tool installations needed for later tasks.
5. Give a short summary of changes, actual checks, and remaining limitations;
   make a local conventional-commit Git commit and include its hash in the final
   report. Never push.
