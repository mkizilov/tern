# Tern compiler design

## Status and scope

The compiler is named `ternc`; its inputs are `.tern` files and its eventual
output is a core WebAssembly `.wasm` module. Prompt 1 establishes the language
contract, example corpus, dependency metadata, and local tooling. Prompt 2 adds
the AST, token vocabulary, and lexer. Prompt 3 adds the parser and source printer;
Prompt 4 adds unified, rendered diagnostics and parser-state messages. Prompt 5
adds resolution/desugaring into Core. Prompt 6 adds HM type inference and the
`ternc check` command. Prompt 7 adds typed match usefulness/exhaustiveness warnings.
Prompt 8 adds the checked-Core reference interpreter and `run --interp` command.
Prompt 9 adds ANF lowering, match decision trees, an IR printer/interpreter, and
`dump-ir`/`run --ir`. Prompt 10 adds explicit closure conversion and converted
execution. There is no WebAssembly backend yet.
`LANGUAGE.md` is authoritative for semantics. Do not infer behavior from OCaml
just because the surface syntax is similar.

## Pipeline and phase contracts

```text
UTF-8 source
  → lexer → parser → surface AST → resolution/desugaring → Core → type inference
                                                                  ├→ reference interpreter
                                                                  └→ ANF lowering → closure conversion
                                                                                     → WAT → wasm-tools → .wasm
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
9. **WAT emission:** choose layouts for tuples, strings, variants, and closures
   in linear memory. Use `i32` for integers, checked allocation, and indirect calls
   for closures. A checked bump allocator is a reasonable first runtime;
   reclamation is not part of Prompt 1. Document the ABI before implementing it.
   Map division traps and match failures to the runtime error contract. Expose
   an entry point and host imports for integer/string output; a future host runner
   must produce the same bytes as the reference interpreter.
10. **Assembly and validation:** call `wasm-tools parse input.wat -o output.wasm`,
    then `wasm-tools validate output.wasm`. Check process status, retain useful
    diagnostics, and clean intermediate files. `wasm-tools` is an assembler and
    validator, **not a WebAssembly execution engine**. Select/test a runner in
    the backend task; no runtime execution is claimed now.

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
