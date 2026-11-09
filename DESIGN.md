# Tern compiler design

## Status and scope

The compiler is named `ternc`; its inputs are `.tern` files and its validated
output is a core WebAssembly `.wasm` module. Prompt 1 establishes the language
contract, example corpus, dependency metadata, and local tooling. Prompt 2 adds
the AST, token vocabulary, and lexer. Prompt 3 adds the parser and source printer;
Prompt 4 adds unified, rendered diagnostics and parser-state messages. Prompt 5
adds resolution/desugaring into Core. Prompt 6 adds HM type inference and the
`ternc check` command. Prompt 7 adds typed match usefulness/exhaustiveness warnings.
Prompt 8 adds the checked-Core reference interpreter and `run --interp` command.
Prompt 9 adds ANF lowering, match decision trees, an IR printer/interpreter, and
`dump-ir`/`run --ir`. Prompt 10 adds explicit closure conversion and converted
execution. Prompt 11 adds the hand-written WAT memory runtime and Node host.
Prompt 12 adds part-1 WAT emission, assembly/validation, build, and compiled run.
Prompt 13 completes heap/data/match/indirect-call emission and Wasm tail calls.
Prompt 14 adds typed differential properties; prompt 15 adds opt-in optimizations;
prompt 16 adds the browser compiler/playground. Prompt 17 adds a non-moving
mark-sweep collector with compiler shadow roots and an arithmetic-interpreter
showcase. Historical prompt sections retain the observations from those turns;
the current memory ABI is specified in the turn-17 section below.
`LANGUAGE.md` is authoritative for semantics. Do not infer behavior from OCaml
just because the surface syntax is similar.

## Pipeline and phase contracts

```text
UTF-8 source
  → lexer → parser → surface AST → resolution/desugaring → Core → type inference
                                                                  ├→ reference interpreter
                                                                  └→ ANF lowering → optional optimization → closure conversion
                                                                                     → WAT + shadow roots/GC → assembler → .wasm
```

The reference interpreter is a semantic oracle, not a transformation that the
backend executes during compilation. Both paths share the resolved, type-checked
program. Keep phases independently testable and free of CLI I/O.

1. **Lexer (sedlex):** produce located tokens with UTF-8 byte offsets and readable
   line/column positions. Handle nested comments, integer-literal boundaries,
   identifiers, and string escapes. Return structured lexical errors.
2. **Parser (Menhir):** produce a location-preserving surface AST. Encode operator
   precedence explicitly. Desugar function-binding shorthand without losing
   diagnostic spans. Parse type declarations and nested patterns; do not resolve
   or infer names here.
3. **AST:** algebraic OCaml types represent expressions, declarations, type
   syntax, and patterns. Use `ppx_deriving` for stable debug printers where useful.
   Keep source spans through subsequent representations.
4. **Name resolution:** produce Core and give each binding and constructor a
   fresh stable identity.
   Resolve shadowing, pattern scope, recursive groups, and primitive names.
   Reject undefined names, duplicate pattern binders, duplicate types or
   constructors, and undeclared type parameters. Constructor arity is known here.
5. **Type inference:** Hindley-Milner unification with an occurs check, fresh
   scheme instantiation, let generalization, and monomorphic recursion within
   each recursive group. Nominal type constructors carry their arities. Check
   unit sequencing and irrefutable bindings, annotate expressions, and report
   located mismatches. Match coverage/redundancy analysis emits warnings;
   non-exhaustive matches still require runtime checks. Normalize type-variable
   names in diagnostics/tests so internal allocation order does not leak.
6. **Reference interpreter:** evaluate the typed resolved AST using environments,
   lexical closures, tuples, and tagged variants. Use explicit 32-bit integer
   operations, not host-dependent OCaml integer overflow. Output goes to an
   injectable sink, so tests capture bytes without mutating process stdout.
   Preserve left-to-right effects and short-circuiting. Return located runtime
   errors for failed matches and invalid arithmetic.
7. **ANF lowering:** name intermediate results with fresh identities, making
   evaluation order explicit. Only atomic operands reach primitive operations
   and applications. Retain branches and pattern decision trees; never hoist
   effects across a branch or evaluate an unselected arm. Test IR invariants.
8. **Closure conversion:** compute free variables and replace functions with
   explicit code/environment pairs. Lift code into module functions; environments
   hold captured values. Recursive groups need shared environments initialized
   before any function can be invoked. Curried functions and partial applications
   keep their semantics. Representation details remain internal.
9. **WAT emission:** use the runtime layouts for tuples, strings, variants, and closures
    in linear memory. Use `i32` integer arithmetic with tagged i64 values, checked allocation, and indirect calls
   for closures. A checked bump allocator is a reasonable first runtime;
   reclamation is not part of Prompt 1. Document the ABI before implementing it.
   Map division traps and match failures to the runtime error contract. Expose
   an entry point and host imports for integer/string output; a future host runner
   must produce the same bytes as the reference interpreter.
10. **Assembly and validation:** call `wasm-tools parse input.wat -o output.wasm`,
    then `wasm-tools validate output.wasm`. Check process status, retain useful
    diagnostics, and clean intermediate files. `wasm-tools` is an assembler and
    validator, **not a WebAssembly execution engine**. Select/test a runner in
    the backend task. Runtime/host execution is now tested independently of emission.

## Planned layout and dependencies

As phases are implemented, place the reusable library in `lib/`, a thin CLI in
`bin/`, and OCaml phase tests in `test/`. Do not create empty modules in advance.
The current `tests/test_project.py` checks only project setup contracts.

`dune-project` generates `ternc.opam` and is the dependency source of truth.
Dune builds/tests/formats; Menhir and sedlex provide parsing/lexing;
`ppx_deriving` provides printers; `ppx_expect` snapshots each compiler phase;
QCheck adds generative tests. `js_of_ocaml` and `js_of_ocaml-ppx` are declared for
later OCaml-in-JavaScript integration, not as substitutes for the Wasm backend.
`ocamlformat` is pinned. Python 3 is a read-only host prerequisite for
infrastructure tests, not a compiler runtime dependency; no Python packages
are needed.

## Local setup and verification

Read `AGENTS.md` first. With the supplied project-local environment:

```sh
scripts/setup.sh
scripts/check.sh
```

Setup supports ARM64/x86_64 macOS/Linux with Bash, a C toolchain, make, tar, curl, and
SHA-256 tooling available read-only. It downloads opam **2.6.1** and wasm-tools
**1.263.0** to `.tools/bin`, verifying platform-specific SHA-256 digests from
their GitHub releases. It initializes the project-local opam root without shell
profile changes, runs `opam switch create . --empty`, installs OCaml **5.4.1**
and Dune, regenerates opam metadata, then runs
`opam install . --deps-only --with-test`. Package builds/downloads use at most two
workers. System dependency installation is disabled (`--no-depexts`). Opam uses
its normal initialization checks; inside this outer macOS sandbox its nested
sandbox was unavailable and opam disabled those hooks in the project-local root.
The outer boundary was not changed. No Homebrew, sudo, services, or global switch is used.
Other dependencies are resolved from constraints, not a fully locked repository.

The environment script preserves supplied HOME/TMPDIR/cache paths and refuses
non-project state paths. Outside the supplied harness, explicitly set HOME to
`$PWD/.agent-local/home` (and unset or localize other external state variables)
before setup. It never resets a supplied project-local value. Toolchains live
in `_opam/`; binaries in `.tools/bin`; caches and extraction directories remain
under `.agent-local/`. Extraction directories are removed on success or failure.
On the supplied macOS command-line toolchain, SDKROOT defaults to the existing
read-only SDK under DEVELOPER_DIR only when SDKROOT is unset; this avoids xcrun
trying to write a host cache. No SDK is installed or modified outside the project.
Re-running setup reuses matching tool versions and the switch. `check.sh`
selects that switch explicitly and runs, fail-fast:

```sh
opam exec --switch="$PWD" -- dune build --root . -j 2
opam exec --switch="$PWD" -- dune test --root . -j 2
opam exec --switch="$PWD" -- dune fmt --root . -j 2
```

For direct commands, select the local environment in the current shell only
(`export PATH="$PWD/.tools/bin:$PATH"` and
`eval "$(opam env --switch="$PWD" --set-switch)"`), then use `dune build`,
`dune test`, or `dune fmt`. All three must pass before a future task is done.
`dune fmt` can promote formatting corrections; rerun the gate afterward.
`dune build @fmt --auto-promote` also applies formatting.
Commit generated `ternc.opam` updates, never `_build/`, `_opam/`, or caches.

Every phase requires `ppx_expect` success and error tests. Add QCheck properties
for unification, substitution, and IR invariants where useful. Once executable,
all fifteen examples must match `.out` byte-for-byte in the interpreter and,
later, a real Wasm runtime. Differential checks must include effect ordering,
closure capture, mutual recursion, nested patterns, and integer edges.

The limitation reports below describe the historical state at each numbered
turn. In turn 10 the repaired environment completed setup and the entire native
gate, including all earlier phase suites and example execution. Current results
are recorded at the end of the closure-conversion section.

### Prompt 1 environment limitation

The mandatory shell sandbox probe passed. Shell HTTPS attempts to both
`api.github.com` and `opam.ocaml.org` failed with curl error 6 (DNS resolution).
No OCaml/opam/Dune installation was present. Release metadata was readable through
the documentation HTTP tool, allowing asset names/digests to be confirmed, but
no alternate execution/download path was used to bypass the shell boundary.
Actual installation, dependency solving, `dune build`, `dune test`, and `dune fmt`
remain unverified here. Standalone Python infrastructure tests can run offline;
their mocked tool calls are not evidence of an installed compiler, a successful
Dune build, or execution of Tern examples.

`scripts/setup.sh` was attempted and exited 6 while downloading its pinned opam
binary from `github.com`; its temporary directory was removed. `scripts/check.sh`
was attempted and correctly rejected the missing local toolchain. The standalone
infrastructure suite passed 14 tests, including mocked bootstrap on all four
supported OS/CPU combinations, repeatability, checksum/download failures,
fail-fast checks, environment preservation, and exact example fixture contents.
These fixtures have not been executed as Tern programs.

Two additional harness observations affect verification: `/bin/sh` could not
change into existing repository directories although Bash/Python could, so
entry scripts use Bash explicitly. macOS `mkdir -p` with absolute project paths
attempted inaccessible ancestor metadata; scripts create validated state paths
relative to the checkout instead. Neither workaround accesses outside the
repository or disables protection. AFT inspection had no Bash diagnostics but
was partial: Python's language server was unavailable and Dune file types had
no diagnostic producer. Native tests, not that partial result, are the evidence.

## Implemented AST and lexer (Prompt 2)

The wrapped OCaml library is `Tern` (public Dune library `ternc`). `Ast` uses a
generic `{ value; span }` wrapper for expressions, patterns, type expressions,
bindings, match arms, constructor/type declarations, top-level declarations,
and the program. Identifier references/binders and operators also retain their
own spans. Literal and operator variants are payloads, not independently
positionless syntax nodes. Every AST type has `ppx_deriving.show` printers.
The AST models curried unary lambdas/applications, recursive binding groups,
conditionals, tuples, matches, sequencing, and parametric variants. No parsing
or semantic validation is performed by these data types.

`Token.kind` is independent of the generated Menhir terminal type.
`Lexer.lex ~file source` returns all located tokens including a zero-width EOF,
or `Error` containing a `Diagnostic.t`. `Lexer.create` and `Lexer.next` also support incremental
token consumption; they raise `Lexer.Error` for lexical failures. Input is a
UTF-8 string and is eagerly validated with OCaml's standard Unicode decoder so
malformed bytes never escape as an unlocated Sedlex exception. Token recognition
and string/comment scanning use Sedlex. Sedlex >= 3.6 is required for parallel
code-point and byte positions. LF is tracked automatically by Sedlex; only lone
CR needs an explicit `new_line` call. Never increment again for LF/CRLF.

All spans use 1-based lines, 0-based Unicode-scalar columns, exclusive end
positions, and 0-based byte offsets. Strings span both quotes even though their
body is scanned in pieces. Nested comment failures point to the outer opener;
unterminated strings point to their quote; invalid escapes cover the backslash
and next scalar. Decimal tokens use an `int64` magnitude bounded by `2147483648`,
with a separate minus token. The future parser must reject a bare extra
magnitude while allowing `-2147483648`; this avoids whitespace-dependent
subtraction and OCaml host-integer overflow. AST integer values use `int32`.

`test/` contains `ppx_expect` tests for AST spans/printers, every keyword and
token kind, maximal munch, multiline/CRLF/lone-CR/tab positions, decoded escapes,
UTF-8 scalar/byte offsets, nested comments, empty/repeated EOF, long-buffer
refills, integer edges, lexical errors, and all 15 examples. Corpus tests only
lex the files; they do not assert parsing, typing, or runtime behavior.

### Prompt 2 verification limitation

Setup was retried and again exited 6: the shell could not resolve `github.com`.
`scripts/check.sh` was attempted and rejected the absent local toolchain. Native
compilation, expectation execution, Dune formatting, and opam regeneration have
not run; authored expectation snapshots are not claimed as observed output.
The 14 existing Python infrastructure regressions and `git diff --check` passed.
Selected span fixture arithmetic was independently checked with Python, not by
executing or reimplementing the lexer. AFT diagnostics were partial because
`ocamllsp` is absent; call-graph inspection also reported OCaml as unindexed,
so the local helper call site was checked with indexed text search instead.

## Implemented parser and source printer (Prompt 3)

`grammar.mly` is the sole grammar, generated through Dune's Menhir 3.0 extension
with type inference, `--strict`, and conflict explanations enabled. Generated
parser/automaton files stay under `_build/`. `Parse.program ~file source` adapts
`Token.t` to the generated terminal type and returns a located `Ast.program`
or a `Diagnostic.t` (unified in Prompt 4). Original token spans travel as semantic
payloads, preserving both Unicode-scalar columns and byte offsets without
trying to encode both in a single `Lexing.position`. Unexpected tokens use the
last supplied token's span; semantic integer/recursive-binding errors use their
own exact spans. No resolver or type-checker runs during parsing.

Application uses a structural left-recursive rule over atoms. Binary operators
are inlined so each production inherits its actual terminal precedence;
comparison operators are non-associative. Unary negation binds below application
and above multiplication. Control-expression productions have lower precedence
than sequencing/operators, keeping their bodies greedy as specified. Match arms
have explicit right-recursive rules: reducing a finished arm/list has lower
precedence than a new bar or an operator. Consequently a bare bar extends the
innermost match, while a parenthesized match permits the next outer arm. These
are explicit language decisions, not arbitrary conflict resolutions; no warning
suppression flags are used. An unused match-expression precedence annotation
was removed during grammar analysis.

`Parse_support` centralizes node-span joining, shorthand desugaring, and the
signed-literal boundary. Unsigned integer atoms remain pending magnitudes until
a syntactic parent forces them into `int32` AST literals. Direct unary minus
can consume `2147483648`; a positive or parenthesized extra magnitude is rejected.
Negative literals normalize to signed `Ast.Int`, while negating a parenthesized
expression remains `E_unary`. Patterns/bindings distinguish irrefutable binding
patterns from general match patterns. Recursive groups syntactically require
names with function bodies. Tuples have at least two elements; types have
postfix application, flat products, and right-associative arrows.

`Pretty.program` produces canonical source, not original formatting/comments.
Compound expressions and constructor payload patterns are parenthesized so
operator, application, sequence, and match scopes cannot change on reparsing.
The printer uses only Tern's five supported string escapes, preserving UTF-8
bytes; OCaml `%S` would introduce unsupported decimal escapes. Function binding
shorthand prints as explicit curried lambdas. A parenthesized operand preserves
the distinction between a negative literal and an `E_unary` node. Type expressions
are parenthesized deliberately rather than relying on minimal-parenthesis logic.

`ppx_deriving.eq` adds syntax equality to the AST. The generic located wrapper's
span field has a custom always-true comparator, so `Ast.equal_program` ignores
spans at every depth, including names and operators, without erasing syntax or
serializing ASTs. Standalone position/span equality remains exact. The parser
expectation suite checks precedence/associativity, applications, nested controls,
the two nested-match interpretations, patterns/types, integer boundaries, UTF-8
spans, errors, empty files, and all 15 examples. Each corpus file must survive
parse → print → reparse with syntax equality; canonical output must also be
idempotent. Changing a literal must fail equality even when spans are ignored.

### Prompt 3 verification limitation

Setup was retried: curl again exited 6 resolving `github.com`, so no native
OCaml/Menhir/Dune toolchain was installed. Native parser generation, conflict
warnings, OCaml compilation, expectation/round-trip execution, opam regeneration,
and formatting remain unverified. AFT also lacks `ocamllsp` diagnostics.

As supplemental analysis, a temporary Python standard-library checker extracted
the grammar alternatives, expanded list/option/inline rules, propagated LALR(1)
lookaheads, and applied the declared precedence rules. The final grammar had
100 productions, 180 states, 301 precedence-resolved action entries, zero
unresolved entries, and no unused explicit precedence annotations in that model.
Its formal parser accepted token streams for all 15 examples and six additional
syntax cases. This is **not** a Menhir run, OCaml semantic-action execution, or
evidence that the authored expectation snapshots passed. The helper is scratch
analysis and is removed before handoff. The existing 14 Python infrastructure
regressions and Git whitespace checks passed; these do not execute the compiler.

## Diagnostics and parser-state messages (Prompt 4)

`Diagnostic.t` is the common compiler error value: severity (`Error`, `Warning`,
or `Note`), a message, primary span, secondary spans with optional labels, and
notes. `Diagnostic.Raised` transports failures inside phases; `Lexer.Error` is
an alias for that exception. `Lexer.lex` and `Parse.program` return the common
value directly. Parser semantic checks use it too. The old parser error record
and lexical/syntax wrapper variants were removed, rather than retaining two
parallel error systems. Lexer cause variants only select messages/notes; they
are not a second returned diagnostic record. Existing span regressions remain,
with the new contextual messages replacing generic unexpected-token text.

`Diagnostic.render ~source` is a plain-text, deterministic string renderer.
`source` is an injected filename-to-optional-text function: the renderer never
opens files implicitly. Each frame prints its location, numbered source line,
and underline; primary frames use carets, secondary frames use dashes and optional
labels. Long multiline spans show the first and last lines with an elision marker.
Exclusive end positions at column zero do not underline the next line. EOF gets
at least one caret, including on a trailing empty line. Missing source/line
context is reported explicitly. Displayed columns start at 1; source spans keep
their existing scalar-column and byte-offset semantics.

For display, tabs use four-column stops and scalar boundaries map to terminal
columns. The new `uucp` dependency supplies Unicode terminal-width hints instead
of duplicating risky width/category tables. Combining and wide characters are
handled using those hints; terminal-specific shaping can still vary. Invalid
UTF-8 bytes render as `\xNN`. Controls, format controls (including bidi controls),
and Unicode line/paragraph separators are escaped, preventing terminal-control
injection from source, filenames, labels, messages, or notes. ANSI sequences are
only introduced by the renderer itself when color is explicitly enabled.

`Diagnostic.emit` defaults to stdout, detects the actual channel's terminal
status with the standard `Unix` library, and flushes output. Redirection disables
color automatically; explicit color overrides support tests/callers. Pure
rendering defaults to no color. No global color setting, subprocess, filesystem
read, or host socket is involved.

The parser now uses Menhir's incremental table backend (`menhirLib`, newly
declared in dependency metadata). `Parse.program` preserves the last token's
primary span and passes accurate byte-based `Lexing.position`s to checkpoints,
while the original scalar/byte spans still travel as token semantic values.
On `HandlingError`, `Grammar_messages.message` selects the state-specific text.
An unmapped state gets an explicit unexpected-token/context message, never a bare
"syntax error". Source semantic failures still carry their own exact spans.

`lib/grammar.messages` contains 18 erroneous token sentences with messages for
bindings, keywords, arrows, parentheses/tuples, comparisons, and types. Dune
compiles it to `grammar_messages.ml` using the same strict/table automaton flags
as the parser; the generated module is not committed. Menhir's `--compile-errors`
checks final-token failure and irredundancy. After grammar changes, use
`menhir --strict --table --list-errors lib/grammar.mly` and
`menhir --strict --table --update-errors lib/grammar.messages lib/grammar.mly`
inside the local opam environment to review coverage/update comments. Capture
output only in project-local scratch files, review before replacing source,
and remove scratch output afterward. Do not hard-code state numbers or suppress
message-validation failures.

A narrow `application_expr` alias is marked `%on_error_reduce`. Completing this
atomic-expression promotion on an invalid lookahead lets an `if` condition and
`match` subject reach distinct enclosing states (and thus say `then` versus
`with`). It does not apply to binary-expression reductions, preserving the
non-associative comparison rejection. No valid expression precedence was changed.

`test/diagnostic_tests.ml` adds ten full rendered syntax-error snapshots and
additional cases for lexer notes, cross-file labeled/unlabeled secondary spans,
severities, multiline/EOF behavior, Unicode/tabs, malformed UTF-8, terminal escape
safety, absent source context, forced color, and redirected emission. The
existing lexer/parser tests still assert message locations and valid-program
round trips; they now consume the common diagnostic API.

### Prompt 4 verification limitation

Setup was retried and curl again exited 6 resolving `github.com`. The local
compiler switch remains absent, so native Menhir/message generation, OCaml
compilation, all expectation snapshots, color emission, formatting, and opam
regeneration remain unverified. `scripts/check.sh` still rejects the missing
toolchain. AFT diagnostics are incomplete because `ocamllsp` and
`pyright-langserver` are unavailable; indexed text search was used after the
call-graph tool reported OCaml files unindexed.

A temporary independent LALR checker validated the 18 message witnesses as
distinct final-token errors in its 181-state model, including the new error-only
reduction. It also confirmed rejection of comparison chains and acceptance of
the 15 example token streams. This is supplemental grammar analysis, not a
Menhir run or execution of OCaml semantic actions/renderers. The helper is
removed before handoff. The standalone infrastructure suite now passes 15 tests,
including the new message-generation/dependency wiring contract. Authored
snapshots are not represented as observed native output.

## Name resolution and desugaring (Prompt 5)

`Resolve.program : Ast.program -> (Core.program, Diagnostic.t) result` is a pure
front-end pass from parsed syntax to the smaller resolved language in `core.ml`.
It does not read files, emit output, evaluate expressions, or perform type
inference. A call creates its own counter and environments. Failure discards
that context; subsequent calls start fresh. Resolution is fail-fast, consistent
with the lexer/parser result APIs.

### Identity and scope

`Core.symbol` contains an integer ID and the original spelling. Located names
at definitions and uses share the symbol but retain their own source spans.
All binders use one allocator across value, type, constructor, type-parameter,
and generated-parameter namespaces. IDs are unique **within a resolved program**,
not globally across separate compilations. Spellings are debug/diagnostic data;
future phases must key environments by ID, not spelling.

The initial metadata describes `print_int` and `print_string` plus the primitive
types `int`, `bool`, `string`, and `unit`. These currently receive IDs 0 through 5
in that order; user/generated IDs start at 6. Do not infer primitive meaning from
those numbers: use `Core.program`'s builtin enum/name pairs. Prelude definition
spans use the explicit virtual filename `<builtin>`; no synthetic file is read
or created. Successful programs keep every allocated binder in Core, including
unused/phantom type parameters and wildcard lambda parameters.

Persistent value maps implement lexical scopes. A nonrecursive pattern is
assigned fresh binder IDs, but its RHS is resolved in the **old** environment;
all pattern bindings become visible only in the continuation. An ordinary shadow
therefore cannot capture references in its own RHS or in an earlier closure.
Recursive groups first allocate and install every function name, then resolve
all bodies in that shared environment. Parameters can shadow recursive names or
outer values with new IDs. Repeated parameters in separate curried lambdas are
separate scopes; repeated names inside one tuple/constructor pattern are errors.
Every match arm gets a fresh pattern scope over the same outer environment.

Type/constructor maps grow in source declaration order, without hoisting future
declarations. A type is installed before resolving its own payloads so recursive
variants work. Its parameters have a declaration-local map, separate from value
and type-constructor names. Duplicate types/constructors are rejected across the
file, duplicate parameters within their type, and duplicate function names within
a recursive group. Reusing a primitive type spelling as a value is allowed;
redeclaring it as a type is not. Constructor patterns check zero/one-payload
shape, and nominal type applications check parameter arity. Ordinary value
application typing and tuple-payload types belong to the next phase.

All unbound/duplicate errors use `Diagnostic.t`. Duplicate diagnostics point to
the second name and label the previous declaration. Unknown type/type-parameter
names and constructor payload mismatches are also resolved here, so later passes
never receive unresolved source names. A constructor value remains a distinct
ID reference, including when used as a first-class payload function.

### Core forms and preserved semantics

Core expressions are literals, value/constructor references, unary name-parameter
lambdas, unary applications, nonrecursive pattern lets, recursive function groups,
conditionals, tuples, matches, and primitive operations. Core has no sequence,
multi-parameter/pattern lambda, boolean operator, separate unary/binary operator,
or top-level value-declaration forms. Types/constructors remain resolved metadata;
top-level values become nested lets in source order ending with a unit literal
at EOF. All expression, pattern, type, declaration, name, and operator nodes retain
source locations; generated nodes reuse the relevant source span.

The parser already normalizes function shorthand and multiple parameters into
nested lambdas. Resolution replaces each variable parameter with its new ID.
Other parameters use a fresh `$arg` identity (not inserted into the source-name
environment), with an inner pattern let for tuple/unit destructuring. A wildcard
parameter needs only the unused fresh lambda binder. Generated spellings cannot
be written as Tern identifiers and, more importantly, references use identities,
so generated binders cannot capture user names.

`left; right` becomes `let () = left in right`, **not** a wildcard let: the unit
pattern preserves the language's sequencing type constraint. `left && right`
becomes `if left then bool(right) else false`; `left || right` becomes
`if left then true else bool(right)`, where `bool(value)` is the Core guard
`if value then true else false`. This guard was added with Prompt 6 so a bad
right operand is diagnosed as a condition, not as a synthetic result branch.
It preserves the earlier lowering's values and single evaluation of operands.
Thus runtime evaluation still short-circuits,
although both branches' names are checked statically. Other operators become
located primitive opcodes with one or two operands. Recursive walks explicitly
resolve callees/conditions/left operands before their siblings, keeping IDs and
diagnostic ordering deterministic rather than relying on OCaml argument order.

Nonrecursive **pattern lets are intentionally retained**. Lowering a polymorphic
tuple binding to a match would make its pattern variables monomorphic and lose
Hindley–Milner let generalization. The future checker must generalize let-pattern
variables against the substituted outer environment. The inner let generated
for a lambda parameter then remains monomorphic because its variables are free
in the lambda argument's environment. Pattern decision-tree lowering belongs
after typing, not in this pass.

### Verification and current limitations

`test/resolve_tests.ml` adds expectations for shadowing/closure references,
nonrecursive RHSs (including tuples), self/local/mutual recursion, parameter and
builtin shadowing, type/value namespaces, constructor/type identities, all listed
error classes, and desugaring. Duplicate error snapshots render both source sites.
A reusable Core invariant walk checks unique and contiguous binder IDs, lexical
scope of value references, resolved type/constructor references, parameter scope,
and primitive arities. Corpus tests apply it to all 15 examples and compare Core
before/after surface pretty-printing. A failure/retry test checks that counters
do not leak between calls. Core has derived printers and span-insensitive equality
using the existing location wrapper.

Native checks are still blocked: setup again exited 6 while resolving `github.com`,
the local switch is absent, and `scripts/check.sh` rejected the missing toolchain.
OCaml compilation, the new expectation/invariant/corpus checks, and formatting
have **not** run; authored expectations are not observed runtime output. No new
dependencies were introduced. The existing infrastructure suite plus a new static
surface-form/Core-constructor coverage contract passed (16 Python tests total),
and Git whitespace checks passed. Static coverage is not a substitute for OCaml
type-checking or semantic execution. AFT could not supply OCaml/Python diagnostics
because their language servers are unavailable, and call-graph inspection reported
the new OCaml file unindexed; indexed search was used for helper references.

## Hindley–Milner inference and check command (Prompt 6)

`Ty` implements the eager level-based algorithm described in Oleg Kiselyov's
[How OCaml type checker works](https://okmij.org/ftp/ML/generalization.html),
specifically the `sound_eager` approach rather than the more elaborate lazy
algorithm. Types are arrows, tuples, nominal constructor applications, or
mutable variable cells. A cell is unbound with an ID/owner level, a link, or a
quantified generic variable. IDs are local to one inference invocation; user
diagnostics never expose them.

`repr` follows links with path compression. When linking an unbound variable to
a type, `occurs_and_lower` rejects cycles and lowers every reachable unbound
variable to the older ownership level before installing the link. This level
lowering is essential: variables used through an outer lambda must not become
polymorphic at an inner let. Structural unification handles arrows, fixed-arity
tuples, and nominal type-constructor IDs. Generic cells are never unified as
mutable metavariables; uses instantiate them first.

Let RHSs and pattern constraints are inferred one level deeper. After checking
them, `generalize` marks only variables whose level exceeds the enclosing level
as generic, without scanning the whole environment. Pattern-let binders are
generalized together after all pattern constraints, so polymorphic tuple bindings
are supported without accidentally quantifying a captured outer variable.
Lambda and match-pattern binders remain monomorphic. Constructor schemes are
built from the resolved variant declarations, quantifying their declared type
parameters (including phantom parameters) and retaining nominal type identity.
Primitive signatures follow `LANGUAGE.md`: arithmetic/integer comparisons,
string concatenation, and fixed print built-ins; equality is not polymorphic.

For a recursive group, fresh monomorphic placeholders at the RHS level are
installed for every member before any body is inferred. Each body is unified
with its placeholder while the entire group remains monomorphic. Only after
all bodies pass are members generalized together relative to the outer level.
This supports ordinary and mutual recursion, but not polymorphic recursion.
It also preserves captured outer variables when a recursive group is local.

`Infer.program` consumes Core and returns top-level binding schemes plus the
program body's type, or `Diagnostic.t`. It infers Core's nested top-level let
spine with a reporting flag; RHSs, lambdas, branches, and matches do not contribute
local names to the top-level report. Reporting includes each named pattern
component and recursive member, preserving source order and shadowed entries.
No partial report escapes on error. Schemes retain mutable nongeneric cells
where needed, so later constraints are reflected when formatted. Successful
schemes' generic variables cannot be specialized by later uses.

Applications first constrain the callee to an arrow, then check the argument
against its parameter type. Operators check operands individually, conditions
require bool, branches/match arms agree on results, and lowered sequencing's
unit pattern requires unit. Diagnostics point to the relevant expression or
pattern rather than only the enclosing declaration. Type errors say `expected
... but got ...`; occurs failures also explain that a variable would contain
itself. `Ty.show_pair` shares a single normalization table across both sides so
related variables retain the same readable name. Printed types use ordinary
arrow/product/postfix precedence and variables `'a` through `'z`, then `'a1`, etc.
`Ty.show` starts normalization anew for each reported binding scheme.

`Check.source` composes parsing, resolution, and inference with one diagnostic
result. The thin `bin/ternc.ml` command supports `check FILE [--types]` via OCaml's
standard `Arg` module. It reads the source once, writes diagnostics to stderr
with injected source text, and prints principal binding schemes only after the
whole pipeline succeeds. No checking mode executes Tern or creates output files.
Success is status 0, front-end/read errors 1, and argument errors 2. The public
Dune executable is `ternc`; use `dune exec ternc -- check FILE --types` or install
it into the local switch. There are no new dependencies.

### Prompt 6 checks and limitations

The native expectation suite contains over 50 small programs covering
polymorphic identity at two types, higher-order functions, aliases, captured
variables and level lowering, closed application/conditional generalization,
tuple lets versus monomorphic tuple parameters/match arms, ordinary/mutual/local
recursion, nominal variants/lists/options, builtin shadowing, and primitive types.
Errors include an infinite self-application type, operand/condition/branch/call
mismatches, bad sequencing, tuple arity, nominal mismatch, constructor-pattern
constraints, and monomorphic recursive uses. Error helpers also check the exact
source slice underlined by each diagnostic. Low-level tests inspect level
lowering, fresh instantiation/sharing, structural occurs checks, naming beyond
26 variables, and state isolation after failure. Corpus expectations check all
15 examples; Cram exercises silent checking, `--types`, status codes, stderr,
and absence of partial stdout on failure.

Setup was retried and still exited 6 resolving `github.com`. The local switch
is absent; `scripts/check.sh` again rejected the missing toolchain. OCaml/Dune
builds, the new native expectations, all corpus type checks, Cram CLI execution,
formatting, and opam regeneration remain **unverified**. Authored snapshots are
not claimed as actual type-checker output. The 18 standalone infrastructure/
static-contract tests and Git whitespace checks passed; they verify setup and
coverage/wiring, not HM semantic execution. AFT lacks `ocamllsp` and reports the
new OCaml files unindexed for call graphs. It classifies the Cram `.t` fixture
as Perl, reporting unsupported Perl analysis and tree-sitter parse errors; these
are not a native Cram runner result. Native Cram validation remains pending.
No sandbox bypass or alternate remote execution was used.

## Typed variants and pattern usefulness (Prompt 7)

Parametric variant/constructor typing reuses the HM pass introduced in Prompt 6:
each constructor has a scheme quantifying its declaration's parameters, payload
patterns constrain those instances, and result types keep their nominal type ID.
Prompt 7 adds dedicated variant typing/library tests and the anomaly checker in
`Coverage`, based on Maranget's
[Warnings for pattern matching, section 3](https://pauillac.inria.fr/~maranget/papers/warn/warn004.html).
The analysis implements the usefulness predicate U and carries a witness vector
through the same recursion. It neither compiles match decisions nor executes code.

### Typed signatures and matrices

Inference records each match's subject type, original cases, and span. Only after
the entire Core program has successfully unified and generalized does it call
`Coverage.check`. This prevents warnings for ill-typed files and lets the checker
observe final type constraints, including nominal arguments. Coverage only reads
types via `Ty.repr`; it never creates metavariables, instantiates schemes,
generalizes, or unifies. Link compression does not change any inferred type.

The catalog maps nominal type IDs to their resolved declarations and primitive
type IDs to their builtin kinds, not to spellings. Constructor payload types are
substituted using the subject's actual type arguments. A constructor has zero
or one argument (a tuple payload remains one argument until its own tuple column
is specialized). Tuples have one constructor of their fixed arity, booleans have
two nullary constructors, and unit has one. Integer and string literals use open
columns with fresh scalar witnesses; functions and unconstrained type variables
can only have wildcard/binding patterns after type checking.

Pattern names are erased into wildcards. Other patterns become constructor,
tuple, or literal heads plus child vectors. For a constructed query, specialization
keeps matching heads, drops incompatible rows, and expands wildcard rows with
wildcard arguments. For a wildcard query with a complete observed signature,
usefulness is searched under every constructor. For an incomplete signature,
only the default matrix (rows whose first column is wildcard) needs checking.
Witness reconstruction reassembles constructor arguments and trailing columns;
an incomplete signature chooses an absent constructor or unused literal. These
are the U equations, not pairwise subsumption or a list of special-case examples.

Case i is redundant when U(P-before-i, case-i) has no witness. Exhaustiveness
queries U(P, wildcard) after all cases. Matrices denote unions, so prefix rows
are stored in reverse order without changing these queries; the original Core
case order is untouched. A universally wildcard row is an immediate coverage
shortcut. Constructor signatures are unfolded only as demanded by finite pattern
syntax, so ordinary recursive list/tree types need no arbitrary depth bound.

### Warning API and witnesses

`Infer.result.warnings` contains `Diagnostic.Warning` values ordered by primary
source position. A non-exhaustive match's primary span is the match expression,
with a note such as `example of an unmatched value: Some None`. A redundant case
points at its own pattern and explains that earlier cases cover it; the covering
set can be a union with no individually subsuming row. Unreachable case bodies
are still resolved and typed. Existing type errors remain fatal and prevent any
warning/type report from escaping a failed check.

Witnesses are Tern pattern-shaped descriptions. They use the existing source
literal printer, fresh 32-bit integer/string literals when needed, and `_` for
arbitrary or unconstrained payloads. A missing list constructor may therefore be
shown as `Cons _`, while an inner list gap can be `Cons (1, Nil)`. The analysis
uses the paper's non-empty-type axiom: it does not separately prove recursive
payload types uninhabited, so those pathological families can produce conservative
warnings. It also does not handle guards, aliases, GADTs, or or-patterns, none of
which are in Tern's syntax. Integer literal columns are treated as open rather
than attempting to enumerate every machine integer. Worst-case pattern matrices
can be exponential; no performance benchmark is claimed for this turn.

The CLI emits warnings on stderr while retaining status 0 and any requested
successful type report on stdout. With no warnings and no `--types`, success is
still silent. Warnings do not alter principal schemes or remove Core cases.
No new dependencies or options were added.

### Verification and environment limits

`test/coverage_tests.ml` covers nested options/lists/tuples, missing constructors
and payload literals, wildcard/binding subsumption, overlapping useful cases,
redundancy from unions, primitive domains, multiple type parameters, warning
spans/order, fatal typing errors in redundant cases, recursive signatures, and
the option/list libraries. It asserts that all 15 examples have no match warnings.
A native finite-product property checks all 512 subsets of nine boolean-pair
patterns against nine queries (4,608 queries), comparing usefulness and every
witness instance with explicit value enumeration. Cram checks warning stderr,
non-fatal status, and simultaneous `--types` output.

The local setup retry again exited 6 resolving `github.com`; the compiler switch
remains absent and `scripts/check.sh` rejected the missing toolchain. Native
OCaml compilation, expectations/properties, library/corpus checks, CLI Cram
execution, and formatting remain **unverified**. No expected snapshot is claimed
as observed compiler output. AFT also lacks OCaml/Python language servers, and its
call graph does not index these OCaml files; the existing Cram-as-Perl tooling
limitation remains.

The available standalone suite passed 19 infrastructure/static-contract tests,
including typed/read-only coverage wiring. Separately, a temporary independent
Python model passed 4,608 boolean-product plus 1,056 option/nested-option
usefulness and witness checks against explicit enumeration. This validates the
modeled recursion, not execution of the OCaml implementation or its substitution
code. The scratch model is removed before handoff. No dependencies were installed
outside the repository and no sandbox boundary was bypassed.

## Reference interpreter (Prompt 8)

`Interp` is the tree-walking semantic reference for later Wasm execution. Its
public interface accepts only `Check.checked`, a private record created by
`Check.prepare` after parsing, resolution, and inference/coverage succeed. That
record retains both immutable Core and the inferred result. This is a checked
Core receipt, not a second AST: runtime evaluation needs no per-node type
annotations. The original `Check.source` API still returns only the inference
result for existing clients. The CLI uses preparation once for either command;
no source effects run if a later declaration fails checking.

### Values, scopes, and recursive closures

Internal values are int32, bool, string, unit, tuples, tagged variants, unary
closures, output built-ins, or unary constructor functions. The public interface
does not expose raw evaluation of unchecked Core. A nullary constructor evaluates
to its tagged variant; a payload constructor is a first-class closed function
that constructs the variant on application. Constructor tags and environment
keys are Core IDs, not spellings. Polymorphic type arguments are erased at runtime.

An environment is a persistent integer map. Ordinary closures store a reference
to the lexical environment present at creation; that reference is not changed.
For each recursive group, one shared environment reference is created, every
member closure is inserted into the complete map, and the reference is tied to
that map before any body or continuation runs. Local groups can escape and keep
their outer values; separate invocations have separate references. Later source
shadows cannot mutate an earlier closure's captured bindings. OCaml's collector
handles the recursive closure/environment cycles.

Each function application evaluates the callee before the argument, then extends
the closure's captured environment with the parameter ID. Explicit field-walking
helpers sequence tuple/primitive operands left-to-right rather than relying on
OCaml argument evaluation order. Only the selected conditional branch evaluates.
The Core short-circuit guard evaluates a needed right operand once and skips it
otherwise. Pattern matching evaluates its subject once, tries cases in source
order, and performs literal/tuple/tag/payload matching. Pattern bindings create
temporary persistent maps; failed patterns never change the next case's starting
environment. Pattern literals compare scalar values, never closure environments.

### Arithmetic, output, and errors

Arithmetic uses the target compiler's standard `Int32` operations (whose API
specifies modulo-2^32 arithmetic), not host `int`. Division truncates toward
zero and remainder has the dividend's sign. Both operations explicitly reject
zero divisors and `min_int / -1` operand pairs, including the corresponding
remainder pair, matching Tern's stricter runtime contract. Comparisons are signed.
Concatenation joins immutable string bytes. Print-int uses signed decimal text;
print-string emits exact bytes. Neither adds a newline.

`Interp.program ~write checked` takes an injected byte-string sink and returns
unit or `Diagnostic.t`. The sink is called as each print occurs, so output before
an arithmetic/match error remains visible. The CLI's stdout sink flushes each
call, keeping source output separate from stderr diagnostics. Runtime match
failure points to the match expression; arithmetic traps point to the operator;
sink `Sys_error` failures point to the write call. A current-span field also
supports best-effort diagnostics for host stack/allocation exhaustion. Interpreter
internal shape assertions are producer/type-checker invariants, not user-facing
dynamic typing. Host resource limits and arbitrary sink exceptions are not
silently hidden; there is no artificial evaluation/fuel limit.

`ternc run --interp FILE.tern` requires the explicit interpreter flag for now.
Front-end warnings are emitted before execution without changing success status.
Runtime/read/front-end errors return 1; argument errors return 2. The existing
check command still never evaluates code. No Wasm runner, hardware, service,
dependency, permanent launcher, or global installation was added.

### Golden corpus and current verification limits

`test/interp_tests.ml` contains semantic expectations for lexical capture and
shadowing, currying/higher-order calls, self/local/mutual recursion, escaping
recursive groups, tail calls, all evaluation-order paths, selected branches and
short-circuit effects, tuple/unit/constructor/literal patterns, builtin shadowing,
int32 wrap/comparison/division/remainder edges, match failure, retained stdout,
source-located runtime errors, sink failure, pre-run checking, and invocation
isolation. Its native corpus loop checks all 15 `.tern` files against their `.out`
files with exact binary-string equality, not trimming or newline normalization.
`test/interp_cli.t` independently loops over the same files using the real public
command and `cmp`, checks the count is 15, and tests partial output/error statuses
and refusal to execute ill-typed code. Dune declares both `.tern` and `.out` inputs.

Setup was retried and again exited 6 resolving `github.com`; the local compiler
switch is still absent and `scripts/check.sh` stopped on that prerequisite.
Native compilation, interpreter expectations, both golden loops, CLI execution,
formatting, and actual example stdout remain **unverified**. No example output
or benchmark timing is fabricated. The 21 standalone infrastructure/static
contracts passed, including coverage of Core forms, the checked-only interface,
recursive environment wiring, and byte-for-byte corpus dependencies. Those
contracts are not semantic execution. AFT lacks the required OCaml/Python language
servers and treats Cram `.t` files as Perl; indexed search was used after the
call-graph tool reported OCaml files unindexed. No sandbox boundary was bypassed.

## ANF and decision-tree match lowering (Prompt 9)

`Anf` is the new located A-normal representation. Atoms are source literals or
resolved names. RHSs are aliases, unary calls, primitives over atom lists, tuple
construction, constructor values, functions, field/payload reads, or a nested
block. Blocks contain named lets, recursive function groups, atom returns,
conditionals, multiway switches, local joins/jumps, and located failure leaves.
No executable `Core.expr`/`Core.pattern` escapes into IR. Function and primitive
arguments cannot contain expressions by construction of their OCaml types.
Control blocks return atoms into a named result before the single continuation.
This avoids the exponential continuation copying of a naive CPS normalizer.

Core now exposes its first unused symbol ID as `next_id`. The resolver's native
invariant walk checks it equals the successful Core binder count. Lowering starts
its private allocator there, preserves source IDs, and allocates globally unique
IDs for intermediate values, fields, payloads, and case labels. Calling lowering
twice does not mutate checked Core or consume any persistent counter. Function
bodies remain nested lexical closures; closure conversion is not implemented in
this turn.

`Lower.normalize` sequences callees, arguments, tuple fields, and operands through
continuations in source evaluation order. Branch bodies normalize independently
to atom returns, while the surrounding continuation runs only once after the
chosen block. Type-checked irrefutable let patterns become aliases and named tuple
projections. Unit/wildcard lets can discard an already-normalized RHS because
typing has enforced any unit constraint; effects are not discarded or hoisted.

### Prioritized match matrices and joins

A match subject is normalized once. Each source case becomes one local join
whose parameters are the case's original binder IDs, and whose action is lowered
once. Rows carry remaining patterns, a join label, source parameter order, and
bindings from source IDs to atom occurrences. The first row controls compilation:
if all its remaining patterns are wildcard/binders, compilation jumps to its
action. Otherwise the first refutable column in that row is moved to the front
with all rows/occurrences, preserving first-case priority.

Tuple columns specialize directly into named indexed field reads. Constructor
and literal columns collect their distinct heads into one switch. Each branch
specializes matching rows plus wildcard/binder rows, retaining original row order;
the default keeps only wildcard/binder rows. A constructor payload read is inside
its tag branch before deeper tuple/constructor/literal tests. Bindings record the
original occurrence, so a bound whole-value fallback receives the whole variant,
not its payload. Empty matrices become `fail "pattern match failed"` at the
original match span. Column removal guarantees progress; types already establish
tuple shape and constructor payload arity.

These are decision trees, not repeated full-pattern tests. Shared case joins
avoid cloning wildcard actions across branches (and duplicating source binder
IDs). Join arguments are atoms and join parameters bind in the action's lexical
environment. They are static control-flow labels, not first-class Tern functions;
lowered user function bodies define their own join scopes. Original source cases,
including unreachable ones, still have well-formed action bodies; warnings remain
the type/coverage pass's responsibility.

### Printing and interpretation

`Ir_pretty.program` prints builtin names, explicit intermediate definitions,
functions, blocks, joins, switches, jumps, projections, and failures. A tag switch
appears as `switch-tag`, followed by its payload/field operations. `ternc dump-ir
FILE.tern` runs the front end and lowering, then prints without source effects.
`ternc run --ir FILE.tern` uses the new interpreter; run requires exactly one
of `--interp` and `--ir`. Check behavior and non-fatal warning reporting remain.

`Ir_interp` independently walks ANF. It evaluates named RHSs, returns values from
blocks, captures case-action environments, binds jump arguments, dispatches switches
through ordered key maps, and reads fields/payloads. Lambda evaluation resets
join scope on a user function call. Recursive IR functions use the same tied
lexical environment model as the AST interpreter. The IR interpreter never calls
the AST evaluator or retries Core patterns.

The former interpreter's runtime machinery was extracted to `Runtime`, with
closure body representation as a type parameter. Both walkers share signed
Int32 arithmetic/traps, constructor values, output built-ins, literal matching,
write failures, and resource diagnostics. This avoids semantic drift without
sharing control-flow evaluation. Resource usage can differ: block continuations
in this initial IR interpreter are not a tail-call optimization pass, and host
stack/allocation limits still apply. No performance benchmark is claimed.

### Verification and remaining limitations

Native IR tests enforce unique/in-scope definitions, atom-only operands,
function-local labels, jump arity, nonnegative field indices, switch-key uniqueness,
and tag-dominated payload reads. They snapshot simple ANF, check grouped constructor
dispatch, and compare AST/IR output and error messages/spans for nested patterns,
fallback binding, subject single evaluation, overlap priority, effects, closures,
recursion, short-circuiting, literal switches, arithmetic traps, and missing cases.
The 15-example loop requires AST output = IR output = exact `.out` bytes. A real
CLI Cram loop repeats all comparisons and checks `dump-ir`/backend selection.

The available Python suite passed 23 infrastructure/static-contract tests.
Separately, a temporary independent decision-tree model matched a linear first-case
oracle for 2,344 ordered boolean-product dispatches and 2,005 nested-variant
dispatch/binding/projection-guard cases. This checks the modeled matrix strategy,
not OCaml lowering, join evaluation, native snapshots, or actual example output.
The scratch model is removed before handoff.

Setup was retried: curl again exited 6 resolving `github.com`, the local switch
is absent, and `scripts/check.sh` stopped at the missing-toolchain prerequisite.
Native OCaml compilation, AST/IR interpreter execution, all differential/golden
tests, CLI execution, formatting, and opam regeneration remain **unverified**.
AFT still lacks OCaml/Python language servers and misclassifies Cram as Perl;
call-graph inspection is unindexed for these OCaml files, so indexed text search
was used. No global dependency installation, boundary bypass, service, hardware,
or host socket was involved.

## Closure conversion and closed-code execution (Prompt 10)

`Free_vars` computes identity-keyed free-variable maps over ANF. It removes let
binders from continuations, lambda parameters from bodies, whole recursive groups
from their shared scope, and join parameters from actions. Jump labels and
constructor-tag metadata are not values. Nested lambda/action uses contribute
their outer dependencies, so an enclosing closure retains values needed to
construct another closure later. Captures are ordered by numeric source ID for
deterministic environment layouts.

`Closure_convert.program` creates a `Closed.program` with a dense, stable,
zero-based function table plus entry block. The closed expression language has
no nested lambda or let-rec function forms. A function definition takes an
explicit environment name and unary source parameter. Capture loads get fresh
local IDs, with source references substituted throughout the body, including
local join actions and nested allocations. A lifted body has no implicit access
to the entry/caller's value environment.

Nonrecursive function values allocate their capture environment and a closure
record `(table index, environment)`. For recursive groups, indices are reserved
for every member before converting any body. A shared layout holds the union of
external captures followed by member closure slots. Conversion allocates the
environment, creates all member records pointing at it, initializes every slot,
then enters the continuation. Each function loads only its actual free variables
from that common layout; self/peer closure values remain first class. The source
case/function/parameter IDs remain unique, while generated environment, load,
call-environment, and initialization IDs start above the ANF range.

Known code indices propagate through lexical function definitions, recursive
groups, and ordinary aliases. At a known call, the callee's environment is
extracted explicitly and `Direct_call` names the constant table index; it does
not dynamically dispatch through the closure's code field. This applies to
known top-level functions and also lexically known local functions. Unknown
higher-order parameters or results use `Closure_call`. This is conservative
lexical knowledge, not whole-program control-flow analysis through arbitrary
tuples, variants, or conditionals. Closure allocation elision is not attempted.

Output builtins and payload constructors receive closed wrapper functions too.
The entry's builtin bindings are uniform closure records, not hidden host lexical
closures. Nullary constructors remain variant data; payload wrappers construct
their tagged result. Wrapper output uses the incoming source call span, keeping
I/O failures located at the user's application rather than a virtual prelude
definition. Primitive arithmetic and byte output still use shared `Runtime`.

The runtime now has compiler-internal environment arrays and closure records.
Uninitialized recursive slots are inaccessible until initialization completes;
they are not source-language references. The source remains immutable and HM
generalization is unchanged. AST and original ANF closures retain their previous
representation for independent reference runs. Converted invocation creates a
fresh value map with exactly the explicit environment/argument before executing
capture loads. No lexical map is stored in converted closure records. Recursive
array/record cycles are managed by OCaml's collector.

`Ir_interp.closed` runs the separate closed-IR walker. The public `run --ir`
pipeline now lowers then converts; default `dump-ir` still prints ANF, while
`dump-ir --closed` prints table functions, captures/layouts, records, environment
operations, and direct/closure calls. Both representations retain original
locations, joins, branch order, and failure leaves. No dependency was added and
no Wasm table/heap layout is emitted yet.

### Verification and current limitations

Native expectations snapshot full nested-closure and recursive conversion,
including builtin wrappers and recursive initialization. Other cases check
free-variable scope, direct top-level aliases versus unknown higher-order calls,
multi-level capture/shadowing, escaping mutual recursion, invocation isolation,
joined case captures, first-class constructors/builtins, and error spans/partial
stdout. A closed-IR invariant walk starts each function with only its environment
and parameter, checks all references are scoped, field indices fit layouts,
labels/jump arities are valid, all binder IDs are unique, and code indices form
a dense table. The corpus requires AST = ANF = closed IR = every `.out` byte
string. The existing public-command corpus now exercises converted execution;
Cram also invokes the optional closed dump.

After the orchestrator repaired DNS, the mandatory shell probe again printed
`SANDBOX_ACTIVE`. Local setup downloaded and verified its pinned tools, then
exposed two host/tooling issues: nested sandbox-exec was unavailable, and cc
could not locate libSystem without SDKROOT. Opam's local initialization disabled
its own unusable hooks; the unchanged outer sandbox still protects the process.
Selecting the existing command-line-tools SDK read-only fixed linking without
installing a system SDK or changing user settings.

The initial 5.5.2 compiler bootstrap succeeded, but project dependency solving
selected OCaml 5.4.1. Setup now explicitly selects that verified OCaml 5 version
and rejects an unexpected final compiler version rather than silently accepting
a solver change. Dune 3.24.2, ocamlformat 0.29.0, and wasm-tools 1.263.0 are
installed locally. Repeating `scripts/setup.sh` succeeded without rebuilding.

The first native build exposed constructor qualification/record inference errors
in the ANF and converted walkers and a location-record initialization in parsing.
These were fixed without changing behavior or suppressing diagnostics. Dune's
read-only source copies also revealed that infrastructure tests must chmod their
owned mock directory/manifest before rewriting fixtures. Structural contracts
now ignore whitespace where formatting may wrap a statement, while retaining
the same required tokens and semantics. Explicit Dune roots avoid probing the
denied parent directory. The pinned formatter promoted previously unformatted
OCaml/Dune sources from earlier turns; these mechanical changes were required
for the complete gate and were not a redesign of those phases.

`scripts/check.sh` now passes: native build, all phase expectations and Cram
tests, the 25 Python infrastructure/static contracts, and formatting. A forced
`dune runtest test --force --root . -j 2` also passed. This includes the full
nested/recursive converted snapshots, closed-scope checks, and actual AST = ANF =
closed IR = golden bytes for all 15 examples. The real `run --ir` CLI corpus
and `dump-ir --closed` checks passed too. No test or golden output was weakened
to obtain these results.

Remaining limitations: no Wasm backend or performance benchmark is part of this
turn. Opam warns that package-publication metadata (maintainer/authors/license/
homepage/bug reports) is incomplete; the later MIT/publication task owns that
work. AFT still lacks ocamllsp and does not index these call graphs; native OCaml
builds/tests are the authority. No outer sandbox boundary was bypassed, no host
service was contacted, and no global tools/settings were changed.

## Initial linear-memory representation and runtime ABI (Prompt 11)

This section records the original bump-only ABI. The turn-17 collector below
supersedes its 8-byte headers, allocation policy, and root-lifetime assumptions;
tagged values and the printing imports are unchanged. Existing compiled binaries
still contain their own runtime and can run with the unchanged Node host.

`runtime/runtime.wat` is hand-written, assembled with the pinned wasm-tools,
validated, and executed in Node. It is a complete runtime module for standalone
helper tests and a body of named `$rt_*` definitions for later backend composition.
It has no source entry point, generated program, start section, collector, or
function table of its own. Tests that add an entry/table are explicitly handwritten
fixtures. Compiler emission remains the next phase, not part of this task.

### Uniform values: unboxed tagged i64

An i32 has exactly 2^32 bit patterns, already all required by Tern's full signed
int32 domain. It cannot also encode booleans, unit, and pointers without boxing
some integers or narrowing their range. The selected scheme uses **one i64 per
value**, keeping integers/booleans unboxed and all heap references uniform.
This trades wider fields/registers for simple monomorphic closure signatures,
full integer semantics, and an unambiguous pointer tag for a future collector.

| Low 3 bits | Meaning | Encoding |
| --- | --- | --- |
| `000` | Heap block | Zero-extended aligned memory32 address; zero is invalid |
| `001` | Integer | `(sign_extend_i32(n) << 3) | 1` |
| `010` | Boolean | False = `2`, true = `10` |
| `011` | Unit | Exactly `3` |
| `100`–`111` | Reserved | Not produced |

Integer decoding is arithmetic right shift by 3 then `i32.wrap_i64`; the public
unbox helper verifies canonical encoding by re-encoding the result. Boolean
unboxing accepts only 2/10. `rt_int` and `rt_bool` construct values; `rt_unit` is
an exported immutable i64 global. The full -2147483648..2147483647 range fits
without allocation. Backend integer operations must unbox, perform wrapping i32
arithmetic, then rebox. Booleans must be unboxed before control flow (encoded
false is nonzero). Division/remainder trap rules remain those in LANGUAGE.md;
in particular a future emitter must also reject the min-int/-1 remainder pair,
which raw `i32.rem_s` would not trap on.

All compiled unary code has type `$tern_function`: `(environment: i64,
argument: i64) -> i64`. The environment value is a pointer to an environment
block, not an OCaml/JavaScript lexical map. Closure dispatch loads the i32 table
index, supplies the environment and argument, and uses this exact indirect-call
type. Known direct calls supply the same explicit environment. File entry
`_start` takes no arguments and has no observable return; no implicit output is
added. No Wasm `(start ...)` section is used, so memory exports exist before
source output begins.

### Heap blocks and headers

Every block is 8-byte aligned and values point to its **header**, not its payload.
All multi-byte words are little-endian. Blocks start at address 4096; the initial
4 KiB is reserved, not managed or scanned by the allocator. The current runtime
starts with one 64 KiB page and caps memory at 1024 pages (64 MiB).

| Offset | Width | Meaning |
| --- | --- | --- |
| `+0` | i32 | `(payload_bytes << 8) | (gc_bits << 6) | kind` |
| `+4` | i32 | Auxiliary constructor tag or function-table index; otherwise zero |
| `+8` | `payload_bytes` | Typed payload |
| After payload | 0–7 bytes | Zero alignment padding, not fields/data |

Kind uses bits 0..5; bits 6..7 are reserved GC flags, initially zero. Size is an
unsigned 24-bit **byte** count, excluding the 8-byte header and padding. Thus a
single payload is at most 16,777,215 bytes. Physical footprint is
`align_up(8 + payload_bytes, 8)`. The auxiliary word is not a tagged value and is
never scanned as a pointer. GC flag bits do not change kind/size inspection.

| Kind | Block | Payload bytes | Auxiliary word | Payload fields |
| --- | --- | --- | --- | --- |
| 1 | Tuple | `arity * 8`, arity >= 2 | 0 | Tagged i64 values |
| 2 | Variant | 0 or 8 | Constructor identity | Optional single tagged payload |
| 3 | Closure | 8 | Function-table index | Tagged environment pointer |
| 4 | String | Exact byte length | 0 | Immutable byte sequence, no terminator |
| 5 | Environment | `field_count * 8`, possibly zero | 0 | Tagged captured/peer values |

Multi-field constructor payloads remain tuple values in one variant slot,
matching Core/Closed. Nullary variants are heap blocks too. Constructor identity
is separate from block kind and from function-table index. A closure is logically
the pair `(code index, environment fields)`, with a separate environment block
allowing recursive members to share it. Environment allocation initializes slots
to unit, then the converted program creates peer records and writes all slots
before invocation. Tuple slots are likewise unit until filled. This is
compiler-internal initialization, not source-visible mutation. There is no new
value restriction or source reference feature.

### Checked bump allocation and helpers

`rt_alloc(kind: i32, payload_bytes: i32, aux: i32) -> i32` is the low-level
allocator, returning a raw memory32 pointer. It validates kind/size, rounds safely,
checks unsigned address overflow and the memory cap, and grows whole pages as
needed. It commits the bump pointer/header only after successful growth and
zeroes payload/padding. Allocation failure traps without advancing the heap, so
a smaller allocation can still succeed. It never frees or reuses a block.
`rt_heap_top() -> i32` is a read-only test/debug query, not an exposed mutable
global. The maximum is an implementation resource limit, not a narrower int range.

The source-oriented helpers use tagged i64 values (`v` below):

| Helper | Signature / result |
| --- | --- |
| `rt_tuple`, `rt_environment` | `(i32 count) -> v` |
| `rt_field_get` | `(v block, i32 index) -> v` |
| `rt_field_set` | `(v tuple_or_environment, i32 index, v field) -> unit` |
| `rt_variant_nullary` | `(i32 constructor) -> v` |
| `rt_variant` | `(i32 constructor, v payload) -> v` |
| `rt_variant_tag`, `rt_variant_payload` | `(v variant) -> i32` / `v` |
| `rt_closure` | `(i32 code_index, v environment) -> v` |
| `rt_closure_code`, `rt_closure_environment` | `(v closure) -> i32` / `v` |
| `rt_string` | `(i32 byte_length) -> v`, initially zero bytes |
| `rt_string_data`, `rt_string_length` | `(v string) -> i32 address` / `i32 byte_length` |
| `rt_string_concat`, `rt_string_equal` | `(v left, v right) -> v string` / `v bool` |
| `rt_print_int`, `rt_print_string` | `(v value) -> unit` |
| `rt_pointer`, `rt_kind`, `rt_size` | `(v block) -> i32 pointer` / `kind` / `payload_bytes` |

Field access checks supported kinds, aligned word size, and unsigned indices;
negative/out-of-range indices trap. Variant writes are not admitted by the generic
setter. Variant payload and closure environment reads check their expected size
and kind. Pointer checks reject noncanonical/high-bit/tagged/misaligned/null,
out-of-heap, and truncated blocks. These checks are not a block-authentication
bitmap: arbitrary malicious Wasm can write its own memory and forge headers.
Trusted generated code must use allocation results and correct field layouts;
this runtime is not a security boundary between mutually hostile Wasm functions.

Strings preserve raw bytes, including embedded NUL; there is no terminator,
Unicode normalization, or runtime UTF-8 re-encoding. Source lexing establishes
valid text; byte-oriented helpers do not discard malformed bytes supplied by a
test/foreign caller. Concat checks combined size through allocation, then copies
both inputs without mutation. Equality is byte equality for literal matching,
not a new polymorphic source equality operator. Literal initialization can copy
raw bytes into a fresh string's data region before publishing it. Allocation
growth does not invalidate numeric pointers, only cached host memory views.

### Host imports and runner

The only imports are `tern.print_int(i32 signed)` and
`tern.print_string(i32 address, i32 byte_length)`, both returning nothing. WAT
printing helpers unbox/check their arguments and return encoded unit afterward.
`runtime/run.mjs` instantiates a binary with these imports, requires exported
`memory`, then calls `_start` for its CLI mode. Its exported `instantiate` helper
also supports a standalone runtime without an entry for tests.

Node writes signed decimal ASCII or exact copied bytes synchronously, without
newlines, and handles partial stdout writes. String imports treat pointer/length
as unsigned i32, check the memory range, and fetch `memory.buffer` afresh on every
call, so `memory.grow` cannot leave a stale/detached host view. Copies prevent a
later memory write from changing an already captured output chunk. No TextDecoder,
WASI, filesystem import, or service socket is provided to the module. CLI usage
errors return 2; instantiation/export/range/trap/I/O errors return 1 with a message
on stderr, preserving previously written stdout. Located compiler runtime error
mapping is not implemented by this host-only step.

### Collector boundary and verification

There is deliberately **no collector**. Objects live until the instance is
discarded. Central allocation, reserved header GC bits, fixed sizes/kinds,
zero padding, canonical pointer tags, and explicit environment/field setters
leave a clear later insertion point. A collector must add root discovery or a
shadow stack for live Wasm locals/arguments, trace tuples/environments/variant
payloads/closure environments, skip string bytes and auxiliary words, handle
cycles, and introduce any required barriers. Header bits alone do not make GC
safe; no root stack, collection trigger, moving pointers, or write barrier is
pretended to exist now.

`runtime/runtime.test.mjs` runs 16 real-Wasm tests via Node 22+ without npm
dependencies. Each runtime/fixture is assembled and validated with project-local
wasm-tools. Tests cover integer extremes/tag rejection, header flags, initialized
fields and bounds, variant layouts, recursive closure cycles, typed table calls,
strings/concat/equality, memory growth, byte-exact printing, allocation failures
and heap consistency under the 64 MiB cap, invalid pointers, and the real host
CLI's output/error/export/range contracts. Tests use project-local temporary
directories and clean them; Node and wasm-tools/Rayon workers are bounded to two.
They are invoked by `runtime/dune` as part of `dune test`. Existing OCaml phase
and 15-example AST/IR tests remain required. No claim is made that a Tern example
has been compiled to Wasm in this turn; only explicit handwritten fixtures are
used for Wasm entry/table integration. Wasm emission and garbage collection are
still out of scope.

Verification for this turn: all 16 runtime tests passed on the read-only Node
26.13.0 host with wasm-tools 1.263.0. `scripts/check.sh` passed native build,
the existing OCaml/CLI suites, the new Dune runtime rule, and formatting.
`node --check` passed for both `.mjs` files. AFT cannot supply JS diagnostics
without a JS workspace marker and has no WAT diagnostic producer; actual Node
execution and Wasm assembly/validation are the authority. No package or global
tool was installed, and no server/watch process was started.

## WAT backend, part 1 (Prompt 12)

`Wat.program : Closed.program -> (string, Diagnostic.t) result` is the pure
emission boundary. It produces a complete module using the Prompt-11 runtime,
with comments naming source functions and numeric SSA-derived Wasm names. Source
aliases identify nonrecursive function literals for readable comments; recursive
definitions already retain their source names. Value locals/parameters are i64;
closed functions use the existing `(i64 environment, i64 argument) -> i64` type.
Code labels are `$fnN`, matching Closed indices without pretending they are the
module's physical function indices. No indirect-call table is emitted yet.

Supported expressions are atom returns, named lets, conditionals and nested
blocks, direct calls, and builtin printing. Returns leave a block value rather
than exiting the Wasm function, so `let x = if ...` and `... + if ...` retain their
continuations. Locals from both branches are declared once; only the chosen branch
executes. Conditions call `rt_unbox_bool`, since encoded false is not raw zero.
Every integer operation unboxes to i32, performs the signed/wrapping operation,
and reboxes; comparison results use `rt_bool`. Negation is wrapping `0 - n`.
Division and remainder helpers reject both zero and min-int/-1 operands before
the machine instruction; the latter remainder check is essential because Wasm
`i32.rem_s` alone would return zero. Arithmetic traps currently become the host's
nonzero runtime failure, not a source-mapped Diagnostic.

Literal strings are the minimal string support required for ordinary printing
and newlines in this subset. UTF-8 bytes become passive data segments, copied into
a freshly allocated runtime string by a literal helper. This avoids a fixed static
data-region limit and preserves bytes/escaping without source-string interpolation
into WAT. Equal literal contents share a data segment but allocations remain
independent; there is no observable pointer identity. String concatenation is
not implemented in this task.

Closed conversion produces environment allocation, capture loads/stores, closure
records, and environment extraction even for direct calls. The backend lowers
these compiler-internal forms through runtime helpers, including shared recursive
initialization. Direct calls name `$fnN` and pass the explicit environment plus
argument; they do not dispatch through the closure code field. A per-function
allocation local is safe because environment fields are atoms, not effectful
nested expressions. Higher-order `Closure_call`, tuples/field projections,
variants/payloads, joins/jumps/switches/match failures, and concat are rejected
with primary source spans. The gate is conservative over all emitted function
bodies, including unused ones; no dead-code or return-code-index analysis is
claimed. In particular, later stages of general curried applications may still
require the pending indirect-call feature.

### Embedded assets, assembly, and CLI

Dune generates `Runtime_assets` directly from `runtime/runtime.wat` and
`runtime/run.mjs`, using quoted OCaml strings. These are the same runtime/host
definitions validated by their own suite, not forked copies maintained in the
backend. The generated module stays under `_build`, while the CLI/library embeds
its contents. A moved executable can build/run without finding repository assets
relative to cwd or reading a guessed source-tree path.

`Wasm_build.emit` composes lower → close → WAT. The file/process boundary then
creates an owned directory under supplied TMPDIR (or project-local fallback),
writes WAT, runs `wasm-tools parse`, then `wasm-tools validate` with checked exit
statuses. Tools are invoked as argv arrays, not through shell interpolation;
paths with spaces are supported. Captured assembler/validator logs become a build
diagnostic on failure. Rayon threads are bounded to two. `build` copies only a
validated binary to an owned temporary file beside the requested output and
atomically renames it; previous output survives every prepublication failure.
Same-input/hardlink output is rejected. Cleanup removes WAT, binary, host, and
logs on both success and failure; build returns no implicit WAT sidecar.

`ternc build file.tern -o out.wasm` requires an explicit output. Default `ternc
run file.tern` assembles/validates in scratch, writes the embedded host there,
then runs Node with inherited stdout/stderr and propagates failure status. Source
output streams normally and survives a later trap. Front-end warnings/errors
retain their prior behavior. `--interp` and `--ir` still select the AST and
converted references; supplying both is an argument error. Dump-IR behavior is
unchanged. Node's executable-entry detection now resolves symlinks, fixing an
actual Dune sandbox case where a linked runner previously returned without
calling `_start`; a runtime regression exercises linked invocation.

### Verification and limits

Phase expectations exercise source-function names/direct calls, integer machine
operations, passive UTF-8 data, actual assembly/validation/Node execution at int32
boundaries, false/unselected branches, conditional result continuations, recursive
direct calls, explicit remainder-overflow guards, stable output, and located
unsupported-feature failures. The real-command corpus compiles examples 01, 02,
03, 05, 06, 07, and 08, validates the artifacts, runs them through the public Node
script, and compares byte-for-byte with both `.out` and default compiled run.
Other CLI checks cover relocated assets, output paths with spaces, input-file
protection, atomic failure preservation, scratch cleanup, and an assembler stub
that returns an invalid binary so the independent validation step must reject it.

No claims are made for the rest of the example corpus under Wasm yet. All 15
still execute through the established AST/ANF/closed interpreter tests. General
closures/data/matches and runtime source-error mapping remain later work; the
runtime remains bump-only with no GC. No new dependency, service, global setting,
hardware operation, or host socket is used.

Verified results for this turn: `scripts/check.sh` passes the native build, all
phase/Cram tests, 27 infrastructure/static contracts, the 16 runtime tests, and
formatting. The 10 new backend expectations and the 7-example compiled corpus
pass with real wasm-tools assembly/validation and Node execution. All four invalid
division/remainder operand cases fail without stdout, and the partial-output case
retains its prefix. The Node runtime suite also verifies symlinked invocation and
library import from stdin. AFT still has no authoritative OCaml/JS diagnostics
in this workspace; the real build, validator, and execution results are the gate.

## Complete Wasm emission and tail calls (Prompt 13)

The backend now covers every executable Closed form. Tuples allocate runtime
blocks and initialize atomic fields left-to-right, using the same allocation
scratch local as environments. Field/payload reads use checked runtime helpers.
Nullary and payload variants carry their nominal constructor identity; payload
tuples remain separate tuple values. Concat calls `rt_string_concat`; string
patterns use byte equality. No source pointer identity or new mutation is added.

### Function table and calls

A single funcref table has one element for every dense Closed code index, in
the same order, including builtin/constructor wrappers. Element N is `$fnN`,
independent of that function's physical module index. Every entry has the
`$tern_function` type `(i64 environment, i64 argument) -> i64`. Normal higher-order
calls load the record's environment and code index and use typed `call_indirect`.
Known targets still name the module function directly. A source function value
is never a hidden host closure.

### Structured decision trees and shared joins

IR joins are emitted once as nested void-labelled blocks inside an i64-result
block. Dispatch exits the selected label, executes its action, then branches
with the result to the shared exit. Lowering's case actions are independent:
they cannot recursively jump to a sibling action. Their nested matches introduce
their own local labels; outer label maps remain lexically scoped. Every formal
argument is first pushed on the operand stack and only then are formals assigned
in reverse order, preserving parallel moves and evaluation order. Local gathering
includes all join parameters/actions and every switch branch.

Constructor switches with a tag span at most 4096 entries use `br_table` over
named arm blocks, with holes and out-of-range tags going to the default. Payload
projections remain inside the matching arm, after the tag decision. Wider sparse
spans use a balanced unsigned tag decision tree rather than a giant jump table.
This avoids code size proportional to arbitrary constructor-ID gaps. Open literal
switches use equality decisions at the selected matrix column: canonical i64
equality for int/bool/unit and runtime byte equality for strings. Subject effects
were already sequenced once by ANF; these tests only read the resulting atom.
No full source-pattern chain is reconstructed. Empty matrices trap, preserving
the warning/runtime-failure distinction and already emitted stdout.

### Tail position and stack behavior

The emitter propagates a tail-position bit through function results, `if` arms,
match actions, and control blocks. An administrative `let result = rhs in result`
or a chain of pure forwarding aliases emits its RHS directly in tail position.
It does not mark a call tail when arithmetic, allocation, or another continuation
still needs its result. A direct tail call uses `return_call`; an unknown target
uses `return_call_indirect` with the same table/type and explicit environment.
Both instructions replace the current Wasm frame, including through selected
match actions. The void `_start` entry does not misuse an i64-result tail call;
its user-function calls follow the ordinary entry/drop convention.

No new general optimizer, uncurrying pass, loop rewrite, or GC is added. The
required stress case is a unary countdown with no per-iteration heap allocation.
Tail calls guarantee bounded stack, not bounded allocations: general curried
applications can still allocate partial closures, and data/string-producing
loops can reach the bump allocator's 64 MiB cap. Non-tail recursion retains its
continuation and can still reach an engine stack limit. Node must support Wasm
tail-call instructions; the verified read-only host does.

### Verification and observed stress result

The public CLI test compiles, validates, and runs all 15 examples, comparing
every output with its `.out` and default compiled run. Focused native expectations
cover indirect/curried calls, captured and case-returned closures, nested tuples
and constructors, wildcard/bound fallbacks, correlated matrix columns, string
switches/UTF-8 concat, left-to-right effects and single subject evaluation, early
wildcard priority, and sparse constructor spans (5001 constructors without a huge
jump table). Earlier arithmetic/atomic-output tests remain, while obsolete
unsupported-feature expectations became positive execution cases rather than
being removed. A non-exhaustive-match CLI regression checks failure and retained
stdout. Tests inspect direct/indirect tail opcodes and non-tail calls, run 100,000
indirect tail steps and 100,000 tail steps through case joins, and run the required
10,000,000-step countdown with heap top below 65536.

An additional actual stress run on Node 26.13.0 returned `42\n` after 10,000,000
tail steps in **0.083357917 seconds** of `_start` execution (assembly/instantiation
excluded). Linear memory remained **65,536 bytes**, heap top was **4,192**
(96 allocated bytes above the 4096 base), and the measured ending process RSS
was **14,207,016 bytes**. RSS is not a peak measurement, and one observed run is
not a speed guarantee. Temporary stress source/binary files were removed; no
large dataset, server, global tool install, or host service was used.

Final gate: `scripts/check.sh` passes native build, all phase/Cram tests, the
expanded 21 backend expectations, all 16 runtime tests, 28 infrastructure/static
contracts, and formatting. All 15 compiled outputs match their goldens and the
10-million-call regression completes without overflow. AFT still lacks ocamllsp
and treats Cram as Perl; real compilation, Wasm validation, and Node execution
are authoritative. Runtime traps still have no Tern source-location mapping.

## Differential corpus and typed properties (Prompt 14)

`test/differential/differential.ml` is the shared test-only execution boundary.
It checks/parses once, captures the AST and closed-IR sinks independently, builds
and validates Wasm through the real builder, then executes a fresh Node instance
with isolated stdout/stderr files. Comparison is exact binary stdout plus a
success bit. This checks failures' output prefixes without claiming identical
diagnostic formatting: Wasm traps are not yet source mapped.

The test host distinguishes a genuine `WebAssembly.RuntimeError` from loader,
export, filesystem, or host errors. Only the former becomes a language-failure
outcome; build errors, unexpected exits/signals, and a 10-second Node timeout
fail the test. The child is killed/reaped on timeout. File descriptors and the
owned workspace are cleaned on failure. No global stdout redirection or concurrent
mutation of the OCaml process's capture state is used.

Corpus discovery is recursive and sorted. Every `.tern` in `examples/` and
`tests/programs/` runs through all engines and also needs an exact `.out`. Optional
`.status` is `ok` or `error`, defaulting to success. The five initial curated cases
cover callee/argument/field effect ordering, captured functions in variants with
later shadows, correlated match-column priority, an arithmetic failure, and a
missing-case failure. Curated coverage is not falsely called generated bugs.

### Typed generation, shrinking, and replay

`Program_gen` constructs a typed term tree, tracking integer, boolean, function,
option, and pair types and a typed lexical environment. Fresh names prevent
accidental capture. The baseline property starts with int32 edges, wrapping
add/subtract/multiply/negation, comparisons, lets, ifs, lambdas/applications,
captured and higher-order functions, and observable output markers. The richer
property adds nested parameterized options (including function payloads), pairs,
and exhaustive option/pair matches. Roots print an integer result and newline.

Depth is bounded to 3..8, and each recursive choice spends fuel. Types guide
arguments, branches, binders, and payload choices. There are no recursive
bindings; this is a strongly normalizing simply typed subset. Division errors
are covered by deterministic fixtures, not hidden by randomized assumptions.
Every generated source must pass the real front end before execution: no filter,
retry, or QCheck discard silently drops an ill-typed sample.

The shrinker returns same-typed constants/subterms, inlines lets and immediate
lambda applications with identity-aware substitution, simplifies known option/
tuple destructuring, and recursively shrinks one child while retaining binder
scope. Candidates strictly decrease `(node count, summed absolute integer/bool
cost)`. The numeric component permits shrinking int32 constants without node
removal and prevents cycles. A 500-case property checks all shrink candidates
with the actual type checker and the decreasing measure. Expect tests reject
newline/status differences and check failure-prefix agreement and beta scope.

The default deterministic seed is 20261108, with 150 cases per execution property.
`TERN_DIFF_SEED` and positive `TERN_DIFF_COUNT` select a replay/longer campaign.
QCheck prints minimized source and engine observations on failure. Tests never
write source regressions automatically, especially inside Dune's read-only copies.
Confirm any discovered mismatch, commit its minimized `.tern`/`.out`/optional
`.status`, fix it, and keep the fixture. Feature counts make construct coverage
visible rather than an empty generator scaffold.

### Bugs and observed campaigns

The first campaign passed all 15 examples, then-two curated cases, 500 typed
generation/shrinking cases, 150 baseline executions, and 150 richer executions
(seed 20261108). Seed 998244353 then passed 500 per execution property plus 500
shrink checks and the expanded five-program corpus. Its richer execution sample
contained matches in 348/500 programs and variant values in 291/500; its baseline
contained closures in 300/500. These are observations, not exhaustive coverage.

After expanding higher-order argument generation, seed 42 passed 300 per
execution property plus 500 shrink checks. Baseline coverage included 170 closure
programs and 69 higher-order programs; richer coverage included 171 closures,
60 higher-order programs, 213 matches, and 178 variant-value programs.

**Compiler/interpreter bugs found: none in these campaigns.** No minimized
failure was fabricated or silently discarded. Harness/generator authoring fixes
(valid unused binder spellings, strict shrink measures, and exact golden newline
conventions) are not compiler bugs. The five fixtures are explicit curated cases,
not invented failing seeds. Any future minimized mismatch must be added as a
regression rather than removed from generation. Existing all-15 compiled goldens
and the 10-million-tail-call test stay enabled; GC, optimization, and publication
metadata remain outside this task.

The final default campaign with the expanded generator passed 150 executions per
property plus 500 shrink checks (seed 20261108), including 32/28 higher-order
programs in the baseline/richer samples and 101 richer match programs. The final
`scripts/check.sh` gate passes native compilation, four harness expectations
(including actual timeout kill/reap), all corpus/property suites, the existing
backend/runtime/CLI tests, 29 infrastructure contracts, and formatting.

One test-orchestration issue was found and fixed: seed/count environment changes
must invalidate Dune's test cache. The property stanza declares both variables as
`env_var` dependencies, so the documented replay command actually reruns cases.
This was not a language-engine mismatch. Context7 did not resolve the OCaml QCheck
package (only unrelated JavaScript libraries); the installed API `.mli`
files supplied the authoritative generator/shrinker/runner signatures. AFT still
lacks ocamllsp; actual builds and executions are the verification authority.

## IR optimization pipeline (turn 15)

`Optimize.program : flags -> Anf.program -> Anf.program` runs before closure
conversion, so it can still reason about lexical lambdas and source constructors.
All flags default off in `Wasm_build.emit/build/run` and the CLI, preserving the
prior pipeline. `build`, compiled `run`, `run --ir`, and both `dump-ir` printers
accept `--inline`, `--const-fold`, `--match-simplify`, `--dce`, or `--opt-all`.
The AST interpreter is never optimized; combining it with these flags is an error.
Enabled passes run once in a deterministic order: inline → constants → matches →
DCE. There is no speculative fixed point, whole-program specialization, or GC.

- **`Opt_inline`** records lexical nonrecursive lambdas/aliases whose transformed
  bodies cost at most 20 ANF expression/RHS nodes. Any nested recursive group
  disqualifies a body; recursive group members are not candidates. Copies replace
  only atom arguments, never re-evaluate an argument, preserve definition-site
  free IDs, and freshen every copied binder, parameter, and join label starting
  at `program.next_id`. Copied bodies are not repeatedly expanded at the call
  site. Unknown higher-order callees remain calls; source spans survive copies.
- **`Opt_const`** propagates literal/copy aliases through lexical scopes, folds
  primitive arithmetic/comparisons/concat with the shared `Runtime` semantics,
  selects constant booleans, and propagates pure block returns. Int32 wrapping
  is exact. Zero divisors and min-int / -1 division/remainder remain runtime
  operations, not compiler exceptions or discarded traps. Concat folding respects
  the runtime's 24-bit byte-size bound. Selected branch effects stay in order.
- **`Opt_match`** tracks constructor functions versus nullary/payload values,
  tuple fields, literals, and aliases. It selects only a proven decision key,
  retaining the default when no key matches, and substitutes projections only
  from proven layouts. It does not treat an arbitrary call as a constructor,
  speculate through a join formal, or erase subject computation. Whole-value
  wildcard fallbacks keep their original value and binder identity.
- **`Opt_dce`** removes unused aliases, lambdas, and total integer primitives.
  Calls, division/remainder, concat, construction, projections, and arbitrary
  blocks remain unless another pass proves a replacement. Recursive definitions
  and join actions use transitive reachability from their continuation, so live
  mutually-recursive peers survive. This is conservative, not an effect system.

No source-visible mutation or pointer identity is introduced. Allocation counts
and exhaustion points may differ when values/functions are eliminated or literals
are propagated; equivalence is for language values, output/effect order, and
language traps, not identical resource usage.

### Tests and measurements

`test/differential/optimizer_tests.ml` tests each pass independently and checks
actual AST/optimized IR/optimized Wasm observations. It covers wrapping/traps,
constant branch effects, unused pure code, recursive reachability, lexical
shadowing, single evaluation, recursion exclusion, globally unique copied IDs
(including nested lambdas/joins), constructor decisions/fallbacks, and determinism.
`test/opt_cli.t` verifies each public flag, IR flags, combined compilation, and
AST-mode rejection. The existing corpus is checked with baseline, every pass
alone, and all flags. The two generated differential properties now optimize IR
and Wasm with all flags while leaving AST unoptimized; typed shrinking remains
unchanged. Existing compiled goldens and the 10-million-tail-call test remain.

Five benchmark sources and a repeatable sequential measurement runner live under
`benchmarks/`; results are in `OPTIMIZATIONS.md`. Each of 30 configurations is
assembled, validated, and compared byte-for-byte to actual AST output. Sizes are
binary file bytes, not WAT text. Runtime medians exclude building/instantiation/
host GC, include execution/output capture, and use fresh bounded-memory Wasm
instances. Identical SHA-256 binaries reveal host/JIT/order noise rather than
false optimizer wins. Bump/memory counters expose allocation tradeoffs; no new
dependencies, external dataset, or persistent benchmark outputs are required.

### Observed verification

The complete `scripts/check.sh` gate passes: native build, 13 optimizer phase
expectations, public CLI flag checks, the optimized 10-million-step tail loop,
all prior phase/runtime/CLI tests, 30 infrastructure contracts, and formatting.
Each of baseline/constants/DCE/inline/matches/all checked the 15-example and
five-program corpus. The default all-enabled seed 20261108 passed 150 executions
per property plus 500 typed generation/shrink checks. Seed 20261109 then passed
500 executions per property plus another 500 shrink checks; richer coverage had
337 match programs, 289 variant programs, and 111 higher-order programs.
No engine mismatch was found; none was fabricated or discarded.

The benchmark runner validated all 30 final configurations and exact outputs.
An earlier batched measurement produced a 62.4% apparent slowdown for identical
list-sort bytes; final measurements rotate/interleave configurations and mark
identical binary content explicitly. The shared host still is not an isolated
performance environment, and these observations are not statistical guarantees.
Scratch is scoped and removed by the runners; no services/watchers are needed.
AFT's OCaml call graph/diagnostics are unavailable here, and it misclassifies Cram
as Perl. Reference search, actual OCaml compilation, native Cram/expect tests,
Wasm validation, and executed comparisons are the authority, not those tool gaps.

## Browser playground (turn 16)

`playground/compiler.ml` is a js_of_ocaml entry point linked to the existing
`ternc` library, not a reimplementation or remote compiler. `TernCompiler.compile`
accepts JavaScript source text and returns plain cloneable objects containing
success, principal top-level types, printed ANF IR, generated WAT, and structured
diagnostics. The path is Check.prepare → Lower → Closure_convert → Wat. Defaults
remain unoptimized, like the native CLI. Browser code never calls Wasm_build's
filesystem/process driver. js_of_ocaml 6.5.0 and the existing OCaml 5.4.1 switch
compile the same parser, resolver, inference, lowering, and backend.

The static UI is CodeMirror 6 with OCaml-like syntax coloring, line numbers,
history, keyboard run controls, lint gutters, and precise diagnostic underlines.
`Diagnostic.render` supplies safe plain-text excerpts; structured primary and
secondary spans are also serialized as half-open UTF-8 byte offsets. The adapter
converts them to CodeMirror UTF-16 offsets without treating scalar columns or
bytes as JavaScript string indices. EOF points, astral characters, CRLF input,
and related-location labels have dedicated tests. Diagnostic/output rendering
uses textContent, never source-driven HTML. Tab semantics and responsive layout
work without an application framework.

Every run gets a fresh worker. It loads the compiled compiler, emits inspection
results, assembles/validates WAT with wabt 1.0.39 (tail_call enabled), and executes
the binary using only the existing tern.print_int / tern.print_string ABI. String
printing checks memory bounds and copies bytes before transferring them to the
UI; decoding is streaming UTF-8 and retains preceding output on a Wasm trap.
The native Node host remains unchanged. Wasm is not evaluated on the main thread.
Stop, editing, navigation, or a five-second deadline terminates the worker; old
worker messages cannot overwrite newer editor state. Source/output budgets are
256 KiB / 64 KiB, and the runtime retains its 64 MiB linear-memory cap. Runtime
traps have no fabricated source span. This is bounded execution, not a new GC or
source-level debugger.

`package.json`/`package-lock.json` pin npm packages, including esbuild 0.28.2 and
Playwright 1.65.0. npm 11's allowScripts policy approves only the exact esbuild
install script. `scripts/build-site.sh` uses existing installed packages, Dune's
js mode, and esbuild to create/minify six local assets in ignored `site/`, with
all 15 sources in a generated dropdown manifest. The compiler's development
inline source map is removed by minification. wabt contains an unreachable Node
fs branch: esbuild marks fs external rather than adding a browser filesystem
polyfill. Real worker tests verify that the branch is never needed. CSP limits
scripts/workers/connections to local assets (with Wasm compilation enabled),
and no CDN or compiler HTTP endpoint is used. `scripts/serve.sh` binds only
127.0.0.1:21916 and serves the built directory; it does not build/install at startup.

### Verification and host observations

The native gate passes with the real JS compiler target included and 31 offline
infrastructure contracts. Five Node tests load the generated compiler in a
browser-like VM and run all 15 goldens through wabt/Wasm byte-for-byte, plus span,
secondary/EOF, partial-trap-output, and invalid-memory-request checks. Eight real
Chromium tests exercise all 15 dropdown examples, all tabs, Unicode errors,
warnings, exact visible output, runtime failures, cancellation/restart, timeout,
output/source limits, safe text rendering, mobile overflow, keyboard controls, and late
example-load races. Requests during runs remain same-origin static GETs. Visual
review found no browser console/page/CSP errors. Other browser engines were not
tested; Wasm tail-call support is required.

Setup fixes were scoped to this work: standalone native linking needed the SDK
selection already supplied by scripts/env.sh; wabt's Node-only fs branch needed
the external declaration; the first copied Dune JS artifact inherited read-only
mode, so the minifying build now writes its own output. The supplied
PLAYWRIGHT_BROWSERS_PATH=0 was preserved by moving this task's downloaded browser
to its native hermetic node_modules location, not by a symlink or global install.
Builds do not reinstall packages and thereby erase that browser. Browser test
output/transform caches are scoped and removed; this host leaves empty Chromium
profile roots, which the runner removes after its owned browser exits. Host-wide
ps inspection is sandbox-denied; owned lifecycle completion and the closed
loopback endpoint verify shutdown without bypassing that boundary. AFT still
lacks OCaml diagnostics and uses a fallback JS analyzer; native builds and actual
executions remain authoritative. The built site and local dependencies are kept
for use; no server, scratch screenshot, or task test report is retained.
Context7 did not resolve js_of_ocaml or wabt to relevant documentation; installed
versioned API/README files supplied those signatures, alongside executed tests.

## Mark-sweep collection and shadow roots (turn 17, current ABI)

The bump-only runtime is replaced by a stop-the-world, non-moving mark-sweep
collector. Tagged i64 immediates, constructor identities, function-table indices,
and the two printing imports retain their semantics. Addresses are stable during
collection. Source code gains no mutable references or observable pointer identity.

### Block layout and allocation

Allocated blocks remain 8-byte aligned but now have **16-byte headers**:

| Offset | Meaning |
| --- | --- |
| 0 | u32: kind in bits 0..5, mark bit 6, reserved bit 7, payload byte size in 8..31 |
| 4 | u32: constructor tag, closure code index, or previous shadow frame |
| 8 | u32: intrusive collector worklist link; not a source field |
| 12 | reserved padding |
| 16 | payload: tagged i64 fields, or opaque string bytes |

Kinds 1..5 remain tuple, variant, closure, string, environment. Kind 6 is a private
shadow frame, not accepted by public source-value accessors or rt_alloc. Free
blocks use kind 0 and encode total block size in 8-byte units in bits 8..31, with
the next-free link at offset 4. Their minimum size is 8 bytes. This distinct free
encoding can represent coalesced regions larger than the 24-bit source payload
limit without truncation. Allocated total size is `(payload + 23) & -8`.

Allocation first searches the free list and splits a fitting block. Otherwise it
uses the high-water cursor while there is capacity. Before growing memory it
collects and retries reuse. Sweep merges adjacent dead/free regions and trims a
dead suffix from the cursor. If retained data still requires more capacity,
memory grows by whole pages, up to the existing 64 MiB cap. Live-data OOM still
traps; collection may run before the failure. Non-moving fragmentation can also
prevent a sufficiently large contiguous allocation. There is no compaction,
generation, concurrent collector, or write barrier.

### Roots, safepoints, and calls

Wasm machine locals/operand stacks are **not** scanned. Every generated callable
pushes a managed shadow frame containing its environment and argument, every
named local/case formal, and allocation scratch. Compiler slot maps use resolved
IDs. Binding stores publish roots immediately; join formals preserve parallel
assignment semantics before their slots are updated. Zero/uninitialized slots
and tagged immediates are ignored by tracing. All bound locals are conservatively
retained until their function returns, even if a later liveness analysis could
prove them dead. This is safe but can retain more memory than a precise map.

Normal returns save the result in a Wasm local, pop/free their frame, then return
without another safepoint. Tail calls evaluate outgoing environment/argument/code
into non-allocating scratch locals, pop their frame, then use return_call or
return_call_indirect. The callee protects incoming environment/argument in runtime
temporary globals **before allocating its own frame**. Thus tail calls remain
bounded in both Wasm stack and shadow-root depth. The ordinary 10-million-call
test is retained, including optimization-enabled execution.

Runtime variant/closure construction and string concatenation likewise protect
their incoming pointer values in temporary roots across allocation. Half-built
environments have initialized unit fields before source code can expose them;
recursive environment/closure cycles are safe to trace during initialization.
Field writes and root stores do not allocate, so stop-the-world collection needs
no mutation barrier.

String atoms must not allocate invisibly while another operand sits unrooted on
the Wasm operand stack. The backend therefore emits immutable literal blocks as
active data starting at 4096 and returns their addresses directly. It sets initial
memory and the managed heap base after the aligned static region. These opaque
static strings are immortal and are never traced or swept. Large literal/static
regions are checked against runtime payload/linear-memory limits.

### Tracing, embedding, and observability

Collection marks the active frame chain and the two runtime temporary roots.
Marking queues each object once using its header work link; a loop drains that
list, traces tagged payload fields and frame links, and skips string bytes and
normal auxiliary tags/code indices. No recursive mark call stack or auxiliary
allocation is needed. Sweep clears live marks and rebuilds/coalesces free blocks.
Cycles become reclaimable when their last shadow-root path disappears.

JavaScript variables are not guest roots. Native embedders retaining a runtime
value across allocating calls must push a frame (at least two reserved slots),
publish values with rt_root_set, and pop frames in LIFO order. Compiler-generated
Tern code does this automatically. A trap aborts the invocation; the collector
does not unwind shadow frames through a Wasm trap. Discard that instance after
a source runtime failure, as the native runner and playground already do.

rt_heap_base exposes the immutable managed-region start; rt_heap_top is the
current high-water cursor, not peak/live bytes. rt_gc_collections counts complete
collections, and rt_allocated_bytes counts successful physical-byte requests,
including reused blocks and shadow frames. Linear memory itself cannot shrink.
The benchmark runner now labels ending managed bytes correctly; OPTIMIZATIONS.md
explicitly preserves its pre-GC measurements rather than inventing replacement
numbers for this ABI.

### Tests and the interpreter showcase

Runtime tests cover cycle retention/reclamation, roots, opaque string bytes,
coalescing/reuse, helper safepoints, LIFO/slot checks, growth, and retained-live-data
OOM. Native stress assertions compile tests/stress/gc.tern in both optimization
modes: two million iterations allocate over 256 MiB cumulatively while linear
memory stays exactly 64 KiB. Each iteration creates at least a tuple, captured
environment, closure, and payload variant; object allocation alone exceeds the
old 64 MiB bump cap. Before invoking the final closure, a non-tail call performs
10,000 further garbage-producing iterations while the closure stays live. Its
answer depends on the exact captured tuple (1, 2), not an algebraic cancellation
that could hide corrupted capture values. It returns 42. After source
return and explicit collection, the cursor returns to the static heap base,
proving that frames/cycles are not leaked. A 20,000-node retained list additionally
forces growth and deep iterative graph tracing, then is fully reclaimable.

The generated-JavaScript corpus test inserts collection at **every allocation**,
including frame creation, and compares all 16 outputs byte-for-byte. This tests
root completeness independently of heap pressure. Native differential/phase/CLI
tests and browser tests include the new examples/interpreter.tern showcase.
Its expression datatype, recursive evaluator, and recursive printer illustrate
the language without changing the language implementation. README is now a
short tour/build/run/testing entry point with a Mermaid pipeline; its two tour
programs are also compiled and executed by tests.

The completed turn passes scripts/check.sh (including 21 runtime tests, all phase
expectations/Cram suites, the GC stress cases, 31 infrastructure contracts, and
formatting), seven generated-JavaScript tests, and eight real Chromium UI tests.
All 16 examples remain byte-exact across the reference/IR/native/browser paths.
The normal all-enabled QCheck campaign passed 300 executions plus 500 typed
generation/shrink checks. Seed 171717 additionally passed 500 executions per
property plus 500 shrink checks; its richer sample contained 330 match and 271
variant programs. No mismatch was suppressed or converted into an accepted trap.
The default and optimized two-million-iteration stress tests and retained-graph
assertions were executed, not extrapolated from RSS. Safari/Firefox and isolated
GC latency benchmarks were not run. AFT still lacks OCaml analysis and treats
Cram as Perl, so native compilation/expect/Cram execution is authoritative.
