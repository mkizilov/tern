# Tern: project boundaries and working agreement

- Work only in `/Users/mk-rune/test_projects/10-tern`. This is one of fourteen independent repositories.
- Do not read, modify, clean up, or run commands in sibling repositories or the user's configuration.
- Work autonomously: choose sensible defaults and document assumptions; do not ask questions or delegate.
- Never install anything globally or use sudo, Homebrew, launchd, host credentials, or host Docker sockets.
- Dependencies, toolchains, caches, browser binaries, SDKs, temporary files and test data stay in this repository. Preserve the supplied project-local environment. Python packages go in `.venv`.
- `.agent-local/` is ignored, project-local build/runtime state. `.opencode/` is managed orchestration configuration; do not change or remove it or bypass the sandbox.
- `.cortexkit/` is ignored, project-local harness state. Preserve it while the harness is active; never commit its caches or metadata.
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
  The target compiler is `ternc`. The surface AST, lexer/parser, diagnostics,
  source printer, Core/resolver, HM inference, and typed match coverage live in
  `lib/`, alongside AST/ANF interpreters, ANF lowering, and closure conversion.
  `bin/ternc.ml` implements checking, `dump-ir`, and `run --interp`/`run --ir`;
  the hand-written linear-memory runtime is in `runtime/`. The WAT backend
  supports the full language and Wasm direct/indirect tail calls.
- Implement phases as a reusable OCaml library under `lib/`, the CLI under
  `bin/`, and phase tests under `test/`, when those phases are requested.
  Keep phases separate, with source locations and structured errors.
- All syntax nodes use `Ast.located`. Spans have 1-based lines, 0-based Unicode
  scalar columns, exclusive ends, and byte offsets. Sedlex already counts LF;
  explicitly count lone CR only. Lexer minus tokens stay separate from integer
  magnitudes; preserve the parser contract for `-2147483648`.
- `Parse.program` is the source-to-AST boundary. Keep Menhir `--strict` enabled;
  resolve conflicts with meaningful rules/precedence, never warning suppression.
  Do not commit generated parser files or `.conflicts` build artifacts.
- `Pretty.program` emits canonical reparsable source. `Ast.equal_program`
  ignores all located spans but compares syntax; use it for round-trip tests.
- `Resolve.program` converts a parsed surface program to `Core.program` or a
  diagnostic. Later passes consume Core, not surface spellings. Identify binders
  by `Core.symbol.id`; spellings are for diagnostics/debugging only. IDs are
  globally unique within a program, deterministic, and reset for each invocation.
- Keep nonrecursive RHSs in the old scope and pre-bind every recursive group
  before resolving its bodies. Preserve pattern `Core.Let` bindings for HM
  generalization; sequence desugaring must retain a unit pattern, not a wildcard.
- `Infer.program` consumes Core and returns inferred top-level schemes or a
  diagnostic. `Ty` uses mutable linked variables, occurs checks with level
  lowering, and level-based generalization. Never generalize a variable reachable
  from an outer level or a recursive member before checking its entire group.
- `Infer.result.warnings` carries non-fatal match diagnostics. Collect match
  subject types during inference, but run `Coverage.check` only after the whole
  program type-checks. Coverage must not unify, instantiate, or generalize types.
- Match usefulness is computed against the matrix of all preceding cases,
  including their column correlations. Preserve witness reconstruction and the
  distinction between a missing case warning and an unreachable case warning.
- Run `dune exec ternc -- check file.tern --types` to check and print top-level
  binding types. `Check.source` is the reusable parse → resolve → infer API.
  Formatting types must use `Ty.show`/`Ty.show_pair`, not internal variable IDs.
- `Check.prepare` returns a private `Check.checked` receipt containing checked
  Core plus inference/warnings. `Interp.program` accepts only that receipt;
  checking must complete before any source effect is executed.
- Interpreter environments use binder IDs and lexical snapshots. Recursive
  groups share an environment tied before any body runs. Preserve left-to-right
  callee/argument/field evaluation, signed Int32 semantics, and streaming output.
- Run `dune exec ternc -- run --interp file.tern`. Native interpreter and CLI
  corpus tests compare every example with its `.out` byte-for-byte, without
  trimming. Runtime errors must preserve already-written stdout.
- `Lower.program` accepts checked Core and produces `Anf.program`. RHS operands,
  call/jump arguments, conditions, and returns are atoms; operation/control-flow
  results are named. Fresh IDs begin at `Core.program.next_id`.
- Match lowering is a prioritized pattern-matrix decision tree: tag switches
  dominate payload reads, tuple projections are named, and case bodies are local
  joins rather than duplicated branch continuations. Keep join labels local to
  a function and preserve source binder IDs and evaluation order.
- `Runtime` is the shared value/primitive/output contract, parameterized by
  closure-body representation. AST and IR walkers must remain separate; the IR
  interpreter must not fall back to Core pattern matching or Core evaluation.
- `Closure_convert.program` lifts every callable into `Closed.program`'s function
  table. Converted functions receive only an explicit environment and argument;
  no implicit lexical/global value map is available inside them. Keep sorted
  free-variable captures, shared recursive layouts, and initialization ordering.
- Statically known functions/aliases use `Closed.Direct_call` with an environment;
  only unknown higher-order values use closure dispatch. Builtins and payload
  constructors have closed wrappers and the same index/environment record format.
- `run --ir` executes closure-converted IR. `dump-ir --closed` shows it; the
  unconverted ANF printer/interpreter remain available for differential checks.
- Use `dune exec ternc -- dump-ir file.tern` or `run --ir`. Differential native
  corpus tests require AST stdout = IR stdout = `.out` bytes, including failures'
  partial output and source locations in focused regression cases.
- Use `Diagnostic.t` for all compiler errors, with a primary span, severity,
  optional secondary labels, and notes. Supply source text to the renderer;
  do not let rendering implicitly read arbitrary filenames. User-facing columns
  are 1-based; internal spans remain 0-based and half-open.
- Parser messages belong in `lib/grammar.messages`, compiled by Dune. Keep
  message witnesses valid and non-redundant after grammar changes. Use the same
  table-backend flags for generation and message compilation. Native compilation
  validates the file; do not hard-code automaton state numbers in OCaml.
- OCaml 5.4.1 is selected for the verified project-local `_opam/` switch. Run
  `scripts/setup.sh` for local opam, dependencies, and pinned wasm-tools.
  Preserve the supplied project-local environment. `DESIGN.md` records host
  prerequisites and the installation limitation observed in turn 1.
- Declare dependencies in `dune-project`; regenerate and commit `ternc.opam`.
  Do not hand-maintain divergent dependency lists. Do not commit toolchains,
  caches, build outputs, or temporary test fixtures.
- `runtime/runtime.wat` defines the memory/value ABI in `DESIGN.md`: tagged i64
  values preserve all int32s, 8-byte-aligned blocks have tag/size headers, and
  closures use a table index plus an environment pointer. Do not shrink int32
  range or introduce source-visible mutation when implementing the backend.
- `runtime/run.mjs` provides only `tern.print_int` and byte-exact
  `tern.print_string`, then calls an exported `_start`. Use a read-only Node.js
  22+ host tool; no npm dependencies are required. No Wasm start section is used.
- `runtime/runtime.test.mjs` assembles/validates WAT with pinned wasm-tools and
  executes it in Node under `dune test`. Keep its scratch paths local and Node/
  Rayon concurrency bounded to two. Runtime tests are not a compiler backend.
- `Wat.program` emits readable WAT from Closed using embedded runtime assets.
  Tables preserve Closed indices; closures use the uniform `$tern_function` ABI.
  Tail position propagates through forwarding aliases and control blocks, never
  through calls with a remaining continuation.
- Match joins are structured blocks with parallel formal assignments. Dense tag
  switches use `br_table`; wide sparse tags use bounded balanced dispatch. Read
  payloads only in their selected constructor branch. Join actions do not recurse
  or jump to siblings; this is the case-join invariant produced by lowering.
- `Wasm_build` assembles then validates before atomic output publication. All
  WAT, host-script, log, and run binaries are scoped scratch and cleaned. `run`
  defaults to compile + Node; `--interp`/`--ir` retain semantic-reference modes.
- Use `dune exec ternc -- build file.tern -o file.wasm` and
  `dune exec ternc -- run file.tern`. All 15 examples must match `.out` when
  compiled, as well as under the interpreter/IR references. The native CLI suite
  includes a 10,000,000-step tail loop with a one-page heap bound.

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
