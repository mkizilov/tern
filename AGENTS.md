# Tern: project boundaries and working agreement

- Work only within this repository.
- Do not read, modify, clean up, or run commands in sibling repositories or the user's configuration.
- Stay within the agreed scope, choose simple defaults, and document assumptions.
- Never install anything globally or use sudo, Homebrew, launchd, host credentials, or host Docker sockets.
- Dependencies, toolchains, caches, browser binaries, SDKs, temporary files and test data stay in this repository. Preserve the supplied project-local environment. Python packages go in `.venv`.
- `.agent-local/` is ignored, project-local build/runtime state. `.opencode/` is read-only managed tool configuration; do not change or remove it or bypass the sandbox.
- `.cortexkit/` is ignored, managed tool state. Preserve active caches; never commit its runtime metadata.
- Use existing system tools read-only, or install pinned tools under this repository. Do not change shell profiles, user settings, Keychain, or global Git settings.
- Bind test servers to loopback; use ports 21900–21999. Limit build/test workers to two unless a required benchmark explicitly needs more.
- Docker-dependent integration tests must remain reproducible but be reported as unverified here if they require access outside this repository. Do not bypass this boundary.
- Do not touch attached hardware, enroll services, flash firmware, install agents, or alter OS settings. Supply manual checklists for such steps.
- Preserve existing behavior outside the requested change. Run appropriate checks, fix regressions, and report genuine limitations without fabricating test or benchmark results.
- Before finishing work: stop owned servers/watchers, remove scratch outputs, update relevant documentation, and make a local conventional-commit Git commit. Do not push.
- Report changes, checks actually run, remaining limitations, and the local commit hash.

## OCaml architecture and local tools

- `LANGUAGE.md` defines Tern semantics; `DESIGN.md` defines phase contracts.
  `VERIFICATION.md` distinguishes evidence from unverified behavior;
  `ROADMAP.md` prioritizes future work, not implemented functionality.
  The target compiler is `ternc`. The surface AST, lexer/parser, diagnostics,
  source printer, Core/resolver, HM inference, and typed match coverage live in
  `lib/`, alongside AST/ANF interpreters, ANF lowering, and closure conversion.
  `bin/ternc.ml` implements checking, `dump-ir`, and `run --interp`/`run --ir`;
  the hand-written linear-memory runtime is in `runtime/`. The WAT backend
  supports the full language and Wasm direct/indirect tail calls.
- Keep reusable compiler phases under `lib/`, the CLI under
  `bin/`, and phase tests under `test/`.
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
  prerequisites, SDK selection, and setup troubleshooting.
- Declare dependencies in `dune-project`; regenerate and commit `ternc.opam`.
  Do not hand-maintain divergent dependency lists. Do not commit toolchains,
  caches, build outputs, or temporary test fixtures.
- `runtime/runtime.wat` defines the memory/value ABI in `DESIGN.md`: tagged i64
  values preserve all int32s, 8-byte-aligned blocks have 16-byte GC headers, and
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
  `dune exec ternc -- run file.tern`. All 16 examples must match `.out` when
  compiled, as well as under the interpreter/IR references. The native CLI suite
  includes a 10,000,000-step tail loop with a one-page heap bound.

## Verification commands and tests

- The Wasm runtime is non-moving mark-sweep. Every generated function pushes a
  shadow frame; locals/join formals/scratch are rooted and frames pop on normal
  returns and before tail calls. Immutable string atoms occupy static blocks.
  Preserve the runtime helper temporary roots across allocating calls.
- GC traces source fields, not string bytes/auxiliary words; it coalesces/splits
  free blocks and collects before growing memory. Host-held exported values must
  be registered explicitly with `rt_frame_push`/`rt_root_set` until released.
- `test/gc_cli.t` checks >256 MiB cumulative allocation in one-page memory with
  both optimization modes, plus a retained 20,000-node graph. Runtime tests cover
  cycles, roots, helper safepoints, coalescing, and live-data OOM. The JavaScript
  corpus also forces GC at every allocation. Do not replace these with RSS-only
  claims or assume a JavaScript local is automatically a guest root.

- `playground/compiler.ml` exports the real checked compiler through
  js_of_ocaml; it uses pure library phases, never the native file/process driver.
  Browser UI/worker sources are under `playground/`. Keep compilation, wabt
  assembly, and Wasm execution client-side and off the main UI thread.
- Install exact npm dependencies with `npm ci` (project-local cache); the lockfile
  is committed. `scripts/build-site.sh` builds/minifies the compiler and bundles
  the static `site/`; it does not reinstall or discard installed browser tools.
  `scripts/serve.sh` serves only `site/` on `127.0.0.1:21916`.
- After building, `npm test` checks the JavaScript compiler/wabt corpus and span
  mapping. `npm run test:browser` checks real Chromium UI behavior with one worker
  and removes its test output. Install the pinned Playwright Chromium locally,
  preserving `PLAYWRIGHT_BROWSERS_PATH` (`0` means hermetic node_modules storage;
  otherwise choose a repository-local path). Never use a global browser install.
- Preserve byte-exact host output, UTF-8-byte → UTF-16 editor span mapping, safe
  text rendering, worker cancellation/time/output limits, and source-edit race
  handling. Runtime traps currently have no source map; do not invent locations.
- `site/`, `node_modules/`, browser binaries, caches, and test scratch are ignored
  generated state, not source deliverables to commit. Preserve the requested
  built site at handoff; stop its server when verification finishes.

- `Optimize.program flags` runs opt-in ANF passes before closure conversion:
  small nonrecursive inlining → constant folding/propagation → known-constructor
  decision simplification → dead code. Defaults remain `Optimize.none`.
  CLI flags are `--inline`, `--const-fold`, `--match-simplify`, `--dce`, and
  `--opt-all` for build/run/dump-ir; the AST interpreter stays unoptimized.
- Preserve effect/trap order, int32 overflow, unique binder/join IDs, and closure
  capture. Do not remove potentially trapping operations as merely unused.
  `test/differential/optimizer_tests.ml` tests each pass separately; the property
  harness uses all passes and also checks the full corpus per individual pass.
- `benchmarks/measure.mjs` reproduces `OPTIMIZATIONS.md` using the existing built
  CLI and Node with `--expose-gc --max-old-space-size=256`; no npm dependencies.
  Measure fresh Wasm instances sequentially; keep generated binaries in scoped
  project-local scratch. Distinguish identical-binary timing noise from wins.

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
- `test/differential` owns the AST/closed-IR/Wasm harness and typed QCheck
  generator/shrinker. Every `.tern` under `examples/` and `tests/programs/` needs
  a byte-exact `.out`; optional `.status` is `ok` or `error` (default `ok`).
- Differential runs compare stdout and success/failure, not renderer-specific
  diagnostic text. Compilation/host failures and timeouts are test errors, not
  accepted language traps. Keep execution sequential and scratch project-local.
- Replay with `TERN_DIFF_SEED` and `TERN_DIFF_COUNT` (150 per execution property
  by default). Keep every confirmed minimized failure as a program fixture;
  tests never silently rewrite source fixtures or accept mismatches.
- `python3 tests/test_project.py` runs offline infrastructure checks directly;
  `dune test` also invokes them. These do not execute Tern or validate a toolchain.
- Each `.tern` example has matching `.out` exact stdout. When an interpreter and
  backend exist, run the corpus against both; keep diagnostics separate from
  stdout. Print built-ins do not add newlines automatically.

## Change checklist

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
