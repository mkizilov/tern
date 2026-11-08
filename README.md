# Tern

Tern is a small functional language targeting WebAssembly, with an OCaml 5
compiler named **ternc**. The project now has a located AST, Sedlex lexer,
Menhir parser, source pretty-printer, unified diagnostics, and name resolution
to a smaller Core AST, Hindley–Milner type inference, and typed pattern-match
warnings. AST and ANF interpreters, ANF lowering, and decision-tree match
compilation and closure conversion are implemented. A hand-written Wasm runtime
and Node host are available. WebAssembly generation supports the full language,
including heap values, matching, higher-order calls, and Wasm tail calls.

- [Language specification](LANGUAGE.md)
- [Compiler design and local setup](DESIGN.md)
- [15 example programs and expected output](examples/README.md)
- [Working agreement and verification](AGENTS.md)
- [Browser playground](#browser-playground)

With the supplied project-local environment, run:

```sh
scripts/setup.sh
scripts/check.sh
```

Setup installs pinned local opam, OCaml 5.4.1 in `_opam/`, declared Dune
dependencies, and pinned wasm-tools in `.tools/bin`. It does not install globally
or change shell profiles. See `DESIGN.md` for prerequisites, environment rules,
and the repaired setup limitations recorded during initial development. On the
supplied macOS toolchain, scripts select its existing read-only SDK only when
SDKROOT is unset. Supplied paths and toolchain settings are preserved.

**Verified in turn 10:** local setup, `scripts/check.sh` (native build, all tests,
and formatting), all phase expectations and Cram suites, and AST/ANF/converted
execution of all 15 exact-output examples. Earlier DNS failures are historical.

Offline infrastructure checks (Python 3 standard library only):

```sh
python3 tests/test_project.py
```

These checks test setup contracts with mocked tools and validate fixture bytes;
they are not a substitute for building OCaml or executing Tern programs.

## AST and lexer

`lib/ast.ml` defines located syntax nodes with derived printers. `lib/token.ml`
defines the token vocabulary; `lib/lexer.ml` exposes `Lexer.lex ~file source`,
returning located tokens (including EOF) or a `Diagnostic.t`.
`Lexer.create` / `Lexer.next` provide incremental token delivery and raise
`Lexer.Error` on invalid input. The input is a UTF-8 string, validated at creation.
Spans use 1-based lines, 0-based Unicode-scalar columns, exclusive ends, and
0-based byte offsets. Tabs advance one column.

Run the AST/lexer `ppx_expect` suite with `dune test -j 2` in the local switch
(or `scripts/check.sh` for all checks). The suite includes every token kind,
positions, errors, and lexical acceptance of all 15 examples. Later phase suites
also parse, check, and execute the corpus. These native suites now pass.

## Parser and source printer

`Parse.program ~file source` returns a located `Ast.program` or a `Diagnostic.t`
with its primary source span. It uses `lib/grammar.mly`, built with Menhir
`--strict`; unresolved conflicts and unused precedence warnings are build
failures, not suppressed warnings. The grammar handles application, operators,
local/recursive bindings, nested matches, tuples/patterns, and parametric variants.
Bare match bars belong to the innermost open match; parentheses close that scope.

`Pretty.program ast` returns canonical Tern source. It desugars function-binding
shorthand and deliberately parenthesizes compound expressions and types. It is
not an OCaml debug dump or a comment/layout-preserving formatter.
`Ast.equal_program` (and the other derived AST equality functions) compares
syntax while ignoring **every** located span, including identifier/operator
spans. Direct `Ast.equal_span` still compares actual source positions.

The parser expectation suite parses all 15 examples, prints/reparses each, and
asserts span-free AST equality and stable printed output. It also tests syntax
errors, integer edges, precedence, and the nested-match ambiguity. They pass in
the verified local switch.

## Diagnostics

Lexer, parser, and parser semantic errors share `Diagnostic.t`: severity, message,
primary span, optionally labeled secondary spans, and notes. Low-level failures
raise `Diagnostic.Raised` (`Lexer.Error` is an alias); the `Lexer.lex` and
`Parse.program` result APIs return the same diagnostic type. The previous
`Parse.Lexical`/`Parse.Syntax` wrappers and separate parser-error record are gone.

Render without filesystem access by supplying source text explicitly:

```ocaml
Diagnostic.render ~color:false
  ~source:(fun file -> if file = "example.tern" then Some source else None)
  diagnostic
```

The result has a rustc-style severity/message header, `file:line:column`, source
excerpt, and caret underline. Displayed columns are 1-based; AST columns remain
0-based. Secondary frames, optional labels, and notes follow the primary frame.
`Diagnostic.render` defaults to plain text for deterministic output;
`Diagnostic.emit` writes to stdout by default and enables ANSI color only when
its actual output channel is a terminal. Redirected output stays plain, unless
color is explicitly forced.

Tabs expand to four-column stops. `uucp` supplies terminal width hints for wide
and combining Unicode characters, avoiding a home-grown Unicode table. Controls,
formatting controls, and malformed bytes are escaped safely in excerpts. Long
multiline spans show their first and last source lines with an elision marker.
Source lookup failures are stated explicitly, never replaced with invented text.

Parser errors use `lib/grammar.messages`, compiled into a state/message lookup
by Dune with `menhir --compile-errors`. The incremental table backend requires
`menhirLib`. Ten syntax-error snapshots plus renderer/lexer regression cases are
in `test/diagnostic_tests.ml`. Native message compilation, snapshots, and color
emission regression tests pass.

## Name resolution and Core

Pass a successfully parsed program to `Resolve.program`. It returns a
`Core.program` or the same `Diagnostic.t` used by the lexer/parser. The resolver
reports unbound values/constructors, duplicate pattern variables, and duplicate
type/constructor names, with secondary spans for previous declarations. It also
resolves type parameters/references, checks type application arity and constructor
pattern payloads, and rejects duplicate names in recursive groups.

Every binder gets a deterministic integer ID, including type parameters,
constructors, prelude bindings, and generated lambda parameters. Names at use
sites carry that identity and their own source span. Shadowing is represented
by different IDs, not string-based lookups in later phases. IDs restart on every
call; there is no global counter or cross-program state.

Core has unary name-parameter lambdas, applications, nonrecursive pattern lets,
recursive function groups, literals, tuples, matches, conditionals, and primitive
operations. Pattern lambda parameters become fresh name parameters with inner
pattern lets. Sequencing becomes a unit-pattern let; `&&` and `||` become
conditionals. Top-level value declarations become nested lets ending in unit,
with resolved type declarations retained as separate metadata. Pattern lets are
intentional: replacing them with ordinary matches would lose let-polymorphism.

Types and constructors are visible after their declaration (and a recursive
type is visible within its own payloads). They cannot be redeclared. Primitive
type names are part of the prelude, while value names such as `print_int` can be
shadowed. The value and type namespaces are separate.

`test/resolve_tests.ml` contains identity/scope goldens, rendered error cases,
desugaring checks, and a corpus invariant walk checking globally unique binders,
properly scoped references, resolved types/constructors, primitive arities, and
stable resolution after source printing. These expectations now pass natively.

## Type checking

Inside the project-local opam environment:

```sh
dune exec ternc -- check examples/11_polymorphic_tuples.tern --types
dune exec ternc -- check examples/15_list_library.tern
```

The public executable's command is `ternc check file.tern --types`; `dune exec`
runs it locally without installing the project. `--types` may precede or follow
the filename. Successful checking without warnings is silent unless that flag
is present; type reports look like `val id : 'a -> 'a`.
Each top-level bound name is reported in source order, including shadowed names
and tuple components, but not wildcard/unit bindings, local bindings, the
prelude, or generated parameters. The whole program must pass before any type
report is printed. Errors go to stderr (with color only on a terminal) and return
status 1; usage errors return 2. No program code is executed.

Pattern warnings go to stderr without making checking fail (status 0). They can
coexist with a successful `--types` report on stdout. Ill-typed files still fail
before any warnings or partial type reports are emitted.

`Check.source ~file source` runs the front-end pipeline and returns inferred
schemes or a diagnostic. `Infer.program` accepts an already resolved Core program.
`Ty` supplies mutable-variable unification, an occurs check that lowers escaping
variables' levels, generalization at let boundaries, and fresh instantiation.
Recursive groups remain monomorphic internally and generalize only after all
bodies are checked. There is no value restriction, matching Tern's immutable
language contract. Constructor signatures, nominal variants, tuple patterns,
short-circuit conditions, unit sequencing, and built-ins are all type-checked.

Mismatches show expected/actual types at the responsible expression. Variable
names are normalized to `'a`, `'b`, … independently for each reported scheme,
and consistently across the expected/actual pair in a diagnostic. Inference
state is local to a call; failures do not poison later checks.

The native suite adds more than 50 program expectations, low-level type-variable
tests, the 15-example typing corpus, and a Cram check-command integration test.
They now pass natively, independently of the Python infrastructure contracts.

## Exhaustiveness and unreachable cases

After type inference, `Coverage.check` applies Maranget's pattern-matrix
usefulness algorithm. A match missing values gets a warning with a witness such
as `None`, `Some None`, or `Cons (1, Nil)`. A case adding no values beyond the
union of preceding cases gets an unreachable-case warning. This handles nested
constructors, tuple-column correlations, wildcards, binding patterns, and scalar
literals—not only duplicate or pairwise-subsumed patterns.

Constructor signatures come from the resolved variant declarations, with actual
type arguments substituted into payloads. Booleans and unit have finite complete
signatures; integers/strings use open-literal columns and fresh witnesses. A
witness is a pattern describing unmatched values: `_` stands for an arbitrary
well-typed payload where a concrete one is unnecessary or unknown. Coverage is
conservative under the paper's non-empty-type assumption; it does not prove
that recursively defined types without finite inhabitants are empty.

`test/coverage_tests.ml` adds nested/partial/redundant pattern expectations,
parametric variant tests, list/option library checks, and a finite-product
usefulness/witness property. The warnings, native tests, and CLI integration
have passed in the local switch.

## Reference interpreter

Inside the local opam environment:

```sh
dune exec ternc -- run --interp examples/01_hello.tern
dune exec ternc -- run --interp examples/15_list_library.tern
```

The reference command is `ternc run --interp FILE.tern`; `--ir` selects the
converted interpreter. Without either flag, run now compiles and executes Wasm.
The complete front end succeeds before execution starts. Warnings go to stderr and do not prevent running;
syntax, resolution, or typing errors prevent every source effect. Success returns
0, source/runtime/read errors return 1, and argument errors return 2.

`Check.prepare ~file source` returns a private checked-Core receipt, retaining
the inferred types/warnings without parsing twice. `Interp.program ~write checked`
evaluates it with an injected string-to-unit output sink. `Check.source` retains
its earlier type-checking-only result API. There is no public unchecked evaluator.

The interpreter uses ID-keyed lexical environments and closures. Recursive
groups share a tied environment; ordinary closures retain the bindings present
at creation. Calls, tuple fields, constructor payloads, and primitive operands
evaluate left-to-right. Strings are emitted as exact bytes, and print built-ins
never insert newlines. Signed 32-bit operations wrap as specified, with explicit
zero-divisor and minimum-integer/negative-one checks for division and remainder.
Failed matches return located diagnostics, not invented values. Output streams
as execution proceeds and survives later failure. The CLI flushes source output
before emitting runtime diagnostics on stderr.

This is the semantic reference for the future Wasm backend. The native suite
includes a 15-file library loop comparing `.out` bytes, a real-command corpus
loop under `dune test`, and semantic/runtime-error expectations. All have now
passed. Python infrastructure tests separately check wiring and setup contracts.

## A-normal IR

```sh
dune exec ternc -- dump-ir examples/15_list_library.tern
dune exec ternc -- run --ir examples/15_list_library.tern
```

`Lower.program checked` produces a located `Anf.program`. Every operation result
is named; functions and primitives consume atoms, not nested expressions.
Conditional/match blocks return atoms to one named result, so their continuation
is not duplicated. Lexical closures remain explicit nested functions until the
closure-conversion pass described below.

Matches compile from a prioritized pattern matrix to multiway tag/literal
switches and projections. Payloads are read only inside their constructor-tag
branch. Each source case body is a local join point with pattern variables as
parameters; leaves jump to it, retaining first-match priority and avoiding
duplicate bodies/binder IDs. No Core pattern nodes survive in executable IR.

`Ir_pretty.program` renders the IR without executing the source.
`Ir_interp.program ~write ir` walks unconverted ANF directly, including join parameters,
switch tables, field reads, and recursive functions. It shares `Runtime` values,
Int32 traps, and byte output with the AST reference, not the AST evaluator itself.
`Core.program.next_id` reserves fresh IDs above every source/prelude binder.

The native tests compare all 15 AST outputs, IR outputs, and `.out` files exactly.
Focused tests cover safe projections, default/bound fallbacks, nested patterns,
column selection, effect ordering, closure capture, and matching error spans.
These native/differential checks now pass, including the original ANF walker.

## Closure-converted IR

```sh
dune exec ternc -- dump-ir --closed examples/09_closures.tern
dune exec ternc -- run --ir examples/15_list_library.tern
```

`Closure_convert.program anf` computes function free variables and lifts all
function code into a top-level table. A closure is explicitly a function-table
index plus an environment record. Function entries take that environment and
their unary argument, loading captures by field index. Builtins and payload
constructors have closed wrappers, so all source-callable values use the same
record format.

Recursive groups allocate one shared environment, make every member closure,
fill captured and peer/self slots, then enter the continuation. This permits
escaping mutually recursive closures while keeping independent invocation state.
Known function literals, recursive members, builtins/constructors, and aliases
use direct calls to constant table indices with explicit environments. Unknown
higher-order parameters remain closure calls; the pass does not guess their code.

`run --ir` now executes this converted representation through `Ir_interp.closed`.
`Ir_interp.program` retains the earlier ANF walker for comparisons. Converted
function calls start with no caller/global lexical map, only their environment
and argument. `Closed_pretty.program` and `dump-ir --closed` expose the table,
capture loads, environment initialization, and direct/indirect call distinction.

Native expectations include nested and recursive converted IR, closed-scope and
call-kind checks, recursive/escaping/higher-order behavior, and AST/ANF/converted
output comparisons for all 15 goldens. These executions now pass in the verified
project-local switch.

## Linear-memory runtime and Node host

`runtime/runtime.wat` is a standalone hand-written runtime module. It provides
tagged values, checked bump allocation, tuple/variant/environment/closure fields,
byte strings, and host printing. The full ABI is specified in `DESIGN.md`.
Uniform values are **i64**, not truncated 31-bit integers: all signed int32 values
remain unboxed and preserve Tern's existing semantics. There is no collector yet.

Run all checks with `scripts/check.sh`. To run only the runtime tests:

```sh
PATH="$PWD/.tools/bin:$PATH" node --test --test-concurrency=2 runtime/runtime.test.mjs
```

Node.js 22+ is a read-only host prerequisite; the verified host uses Node 26.
Tests assemble and validate WAT using project-local wasm-tools, execute helpers
and hand-written entry fixtures, and clean their temporary files. They run as
part of `dune test` alongside the OCaml and existing CLI suites.

The host runner's public command is:

```sh
node runtime/run.mjs FILE.wasm
```

A module must export `memory` and a callable `_start`; its imports are
`tern.print_int(i32)` and `tern.print_string(i32 pointer, i32 byte_length)`.
Output is raw bytes with no implicit newline. Failures return status 1 and
diagnostics on stderr, preserving prior stdout; argument errors return 2.
The runtime by itself intentionally has no `_start`. Runtime-unit tests use
explicit handwritten WAT fixtures; separate backend tests now compile and run
the supported Tern corpus listed below.

## Build and run Wasm

```sh
dune exec ternc -- build examples/07_factorial.tern -o factorial.wasm
node runtime/run.mjs factorial.wasm
dune exec ternc -- run examples/08_mutual_recursion.tern
```

`ternc build FILE.tern -o FILE.wasm` emits WAT, assembles it with `wasm-tools
parse`, validates it with `wasm-tools validate`, then atomically publishes only
the validated binary. A failed check, unsupported feature, assembler, or validator
does not replace an existing output. Building over the input source is rejected.
`ternc run FILE.tern` uses the same compiler and embedded Node host, with no
persistent build artifacts. Put `.tools/bin` on PATH when invoking the executable
directly; `scripts/check.sh` already selects the local tools. The binary embeds
its WAT runtime and host source and does not depend on the launch directory.

The backend preserves all signed int32 values, wrapping arithmetic, signed
comparisons, booleans/short-circuiting, `if` block values, `let`, unit sequencing,
tuples, variants, nested matches, lexical closures, higher-order/recursive calls,
byte strings and concatenation, and exact integer/string printing.
Readable WAT is available through the reusable `Wat.program`/`Wasm_build.emit`
APIs, including comments naming source functions. Build keeps no implicit WAT
sidecar; temporary WAT and execution files are cleaned.

All **15 examples** compile, validate, run, and match their `.out` bytes under
both the public build/Node path and default run. A typed function table supports
indirect closure calls; known callees remain direct. Match matrices become tag
dispatch and field reads with shared structured case joins. Literal string cases
use byte equality, and runtime concatenation does not alter either input.

Calls in actual tail position use `return_call` or `return_call_indirect`.
Forwarding lets and branch/match result blocks preserve tail position; arithmetic
or other work after a call does not. The test suite runs 10 million tail calls
without stack overflow and with linear memory below one page, plus separate
indirect and case-join tail tests. Use a Node engine supporting Wasm tail calls;
the verified host is Node 26.13.0.

The bump allocator still has no collector: tail calls bound stack use, not heap
allocation. Curried calls that construct intermediate closures, tuples, variants,
or strings may exhaust the documented 64 MiB cap. Native/runtime failures preserve
prior stdout; Node currently reports traps without Tern source-location mapping.

## Differential and property testing

`test/differential` runs a shared harness over **every** `.tern` in `examples/`
and `tests/programs/`. Each case executes through the AST interpreter, the closed
IR interpreter, and assembled/validated Wasm. Stdout bytes and success/failure
must match across all three, including partial output before arithmetic or match
failure. Fixture `.out` files provide an additional exact oracle; `.status` may
contain `error` for an expected runtime failure.

The same harness is a QCheck property for bounded well-typed programs. One
property generates integer arithmetic, lets, conditionals, captured/higher-order
functions, and output markers; a second adds parameterized options, tuples, and
matches. A typed shrinker reduces failed cases while preserving scope/type and a
strictly decreasing size/constant-cost measure. A separate property type-checks
generated terms and their shrink candidates. There are no filtered/discarded
invalid samples.

These tests are part of `scripts/check.sh`. To replay or extend a sample:

```sh
TERN_DIFF_SEED=42 TERN_DIFF_COUNT=300 scripts/check.sh
```

The default seed is `20261108`, with 150 programs per execution property plus
500 generation/shrinking checks. Node has a 10-second timeout; generated sources
are nonrecursive with bounded depth, and every case gets a fresh Wasm instance.
Tools remain bounded to two workers. Failures print the seed, minimized source,
and engine observations; keep confirmed minimized bugs under `tests/programs`
with expected stdout/status. Tests do not mutate source fixtures or retain scratch
output. `DESIGN.md` records actual campaigns and any bugs found.

## Opt-in IR optimizations

The default compiler remains unoptimized. Enable passes independently or together:

```sh
dune exec ternc -- build examples/07_factorial.tern --const-fold --dce -o factorial.wasm
dune exec ternc -- run --opt-all examples/15_list_library.tern
dune exec ternc -- dump-ir --inline --match-simplify examples/14_variant_tree.tern
```

`--const-fold` folds/propagates constants, `--dce` removes dead pure bindings and
unreachable functions/case actions, `--inline` copies small nonrecursive bodies,
and `--match-simplify` selects decisions on proven constructors/literals and
their fields. `--opt-all` runs inline → constants → matches → DCE. The same flags
work with `run --ir` and `dump-ir --closed`. `run --interp` deliberately remains
the unoptimized semantic oracle and rejects optimization flags.

Each pass has its own expect tests and all-corpus differential checks. Generated
AST/IR/Wasm comparisons enable every pass; interpreter stdout/status must still
agree. Optimizations preserve effects and language traps, not the exact point of
resource exhaustion. Inlining can increase code size; literal propagation can
increase allocations. No pass promises universal improvements.

`benchmarks/` contains naive Fibonacci, insertion sort, a persistent tree map,
string building, and closure-heavy programs. `OPTIMIZATIONS.md` records actual
Wasm byte sizes, median execution times, and bump-memory usage with every pass
disabled, each pass alone, and all enabled. It includes the reproducible command,
warmup/timing boundaries, binary-content comparisons, and limitations.

## Browser playground

The compiler itself runs as JavaScript generated by **js_of_ocaml**. CodeMirror 6
provides the editor; a worker type-checks and compiles Tern to WAT, assembles it
with the locally bundled **wabt** package, and executes the Wasm in your browser.
No source is uploaded and no server-side compiler or wasm-tools is needed.

With the supplied project-local toolchain/environment:

```sh
npm ci --cache "$XDG_CACHE_HOME/npm" --no-audit --no-fund
scripts/build-site.sh
scripts/serve.sh
```

Open **http://127.0.0.1:21916**. `site/` is a complete static build and can also
be hosted under a subdirectory on a static HTTP server. Do not open it with
`file://`: workers and fetch require HTTP. The build script leaves installed
dependencies/browser binaries intact; run `npm ci` explicitly when dependencies
change. npm's project-local policy approves only esbuild's pinned install script.

Choose any of the 15 examples, edit it, and press **Run** or **⌘/Ctrl+Enter**.
The same button stops a running worker. The output pane preserves text written
before a trap; compiler diagnostics show source excerpts and underline the exact
primary/secondary spans, including Unicode. Warnings are non-fatal. Tabs show
inferred types, ANF IR, and generated WAT. Editing clears stale results and
cancels an in-flight run; late example loading does not replace your edits.

Runs have a five-second worker budget, a 256 KiB source limit, 64 KiB output
limit, and the existing 64 MiB Wasm memory cap. The text pane decodes output as
UTF-8 (invalid byte sequences display replacement characters). Runtime traps
remain unmapped to Tern source locations. Use a modern browser with Wasm tail-call
support; this turn verified pinned headless Chromium, not Safari or Firefox.

Verification, after building the site:

```sh
scripts/check.sh
npm test
PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$PWD/.agent-local/browsers}" \
  node_modules/.bin/playwright install chromium --only-shell
npm run test:browser
```

The browser-path setting is preserved; this environment supplies `0`, so its
binary is installed hermetically under `node_modules/playwright-core/`. Running
`npm ci` replaces node_modules and requires reinstalling that browser afterward.
The browser test runner owns/stops its loopback server and removes transient
results. `site/`, npm packages, and browser binaries are generated and ignored.
