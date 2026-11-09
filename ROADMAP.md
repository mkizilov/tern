# Tern roadmap

This is prioritized **future work**, not a list of functionality already shipped.
The reviewed compiler baseline is `290fbf3`. See [VERIFICATION.md](VERIFICATION.md)
for current evidence and [DESIGN.md](DESIGN.md) for implementation contracts.

The original language/compiler, four opt-in optimizations, five benchmarks,
browser playground, interpreter showcase, and mark-sweep stretch goal are
implemented. Remaining work is primarily verification depth, runtime diagnostics,
resource hardening, reproducibility, and publication readiness. In particular,
`opam lint ternc.opam` currently fails for missing maintainer metadata and reports
additional publication-field warnings. Nothing below should be advertised as
implemented merely because it has an estimate.

### Priority and estimate assumptions

- Steps 1–7 address correctness/security gaps first: **98 hours**.
- Steps 8–13 address reproducibility, compatibility, evidence, and release gates:
  **70 hours**. Release metadata precedes the lower-priority additions.
- Steps 14–16 are later improvements/features: **48 hours**.
- **Total estimate: 216 engineer-hours**, plus **54 hours contingency** (25%),
  for a **270-hour planning budget**. This is effort, not a delivery-date promise.
- Estimates include implementation, focused regressions, review, documentation,
  and relevant existing checks. One engineer is assumed to know OCaml/Wasm/JS and
  have the current local toolchain. Existing CI runners/SDKs and owner-approved
  publication facts are assumed available; provisioning/approval wait time is
  excluded. There is no parallelism discount or duplicated testing allowance.
- Dependencies below are numbered prerequisites, not permission to broaden scope.
  Work stays repository-local, with at most two ordinary build/test workers;
  external-platform execution remains unverified until actually run.

## 1. Strengthen GC root and allocator verification

- **Scope:** Add a model-based heap test covering randomized root registration,
  cycles, interior holes, split/coalesce boundaries, helper temporaries, and
  forced collection under every optimization combination used by the suite.
- **Rationale:** `runtime/runtime.wat` and `lib/wat.ml` now have a real collector,
  but directed stress and sixteen forced-GC examples are not a general memory-
  safety proof. Root omission has the largest correctness blast radius.
- **Dependencies:** None.
- **Acceptance criteria:** At least 10,000 deterministic model operations preserve
  all rooted graphs and reclaim unreachable cycles; minimized failures become
  fixtures. Existing one-page churn, 20,000-node graph, live-data OOM, and tail-call
  tests still pass. No test treats a JS variable as an implicit guest root.
- **Effort:** 18 hours.

## 2. Bound adversarial compiler resource usage

- **Scope:** Add explicit work/output budgets for parsing, type rendering,
  coverage matrices, and WAT generation, including adversarial well-typed inputs.
  Preserve cancellation rather than claiming browsers offer a hard worker-heap cap.
- **Rationale:** The playground bounds source bytes and time, but `Ty.format_many`
  and recursive compiler traversals can expand shared types or pathological
  patterns substantially before the worker deadline. Native checking is unbounded.
- **Dependencies:** None.
- **Acceptance criteria:** Deep syntax, repeated type duplication, and large match
  matrices fail with deterministic located budget diagnostics rather than process
  OOM/unhandled stack errors. Normal corpus output/types remain unchanged and
  documented worker limits still terminate hostile runs.
- **Effort:** 16 hours.

## 3. Separate language traps, resource failures, and instance lifecycle errors

- **Scope:** Introduce a stable runtime fault classification for arithmetic,
  failed matching, heap exhaustion, and internal faults; define a checked one-shot
  instance API or safe recovery contract for native/browser hosts.
- **Rationale:** Generated failures largely use `unreachable`; the differential
  runner groups WebAssembly.RuntimeError failures together. Shadow frames are not
  unwound through traps, so current callers must discard a failed instance.
- **Dependencies:** 1.
- **Acceptance criteria:** Tests distinguish intentional language traps from
  resource/internal/host failures, retain prior stdout, and reject unsupported
  post-trap reuse. Compile/host errors and timeouts cannot become passing language
  failures in the differential harness.
- **Effort:** 12 hours.

## 4. Add source-mapped compiled runtime diagnostics

- **Scope:** Carry source-site identifiers from Closed operations into runtime
  fault reporting, native rendering, and playground editor highlights.
- **Rationale:** Front-end diagnostics have real spans, but compiled runtime traps
  currently lack them. This is a remaining diagnostic-quality gap, not a missing
  parser/type-checker implementation.
- **Dependencies:** 3.
- **Acceptance criteria:** Division/remainder, failed matches, and marked
  allocation/call failures report the responsible source site with Unicode-
  correct ranges. The CLI and browser preserve partial output and do not present
  a guessed Wasm stack location as an exact Tern span.
- **Effort:** 14 hours.

## 5. Expand negative host and playground security tests

- **Scope:** Exercise malformed bridge messages, output-flood patterns, hostile
  diagnostic text, ABI misuse, cancellation races, and source/resource boundaries.
  Document that the host is not a hardened arbitrary-Wasm execution service.
- **Rationale:** CSP, textContent rendering, checked print ranges, worker isolation,
  and limits are implemented, but happy-path examples and selected negative cases
  do not cover all boundary interactions.
- **Dependencies:** 2, 3.
- **Acceptance criteria:** No source-derived HTML executes; no unexpected imports
  or uploads occur; invalid ranges/messages fail explicitly; timeout/cancel/flood
  cases release owned workers and retain the documented output prefix. CSP is not
  weakened to make tests pass.
- **Effort:** 10 hours.

## 6. Validate recursive pattern-coverage corner cases

- **Scope:** Extend `Coverage.useful` verification to uninhabited recursive types,
  parameter substitutions, nested column correlations, and witness validity.
- **Rationale:** Typed usefulness and ordinary list/option coverage are present;
  treatment of impossible recursive values is conservative and deserves explicit
  evidence before stronger exhaustiveness claims.
- **Dependencies:** None.
- **Acceptance criteria:** Finite reference-model cases agree on usefulness;
  emitted witnesses type-check and are actually uncovered. Impossible-value
  behavior is specified/tested, prior warnings remain stable where correct, and
  coverage does not unify or generalize inference variables.
- **Effort:** 12 hours.

## 7. Broaden differential generation and malformed-source fuzzing

- **Scope:** Add bounded recursion, strings, arithmetic-failure cases, richer
  variants/joins, and GC-pressure generation; compare native/JS compilation and
  both assemblers. Keep well-typed and malformed-source campaigns distinct.
- **Rationale:** The current QCheck generator covers integers, booleans, lets,
  closures, options, pairs, and effects, but not the entire language or resource
  surface. Sampling success is not universal equivalence.
- **Dependencies:** 1, 2, 3, 6.
- **Acceptance criteria:** Replayable long campaigns cover each new construct and
  forced safepoints; shrink candidates preserve the relevant type/scope or error
  invariant. All confirmed minimized failures are committed, with no filtered
  mismatches or accepted infrastructure errors.
- **Effort:** 16 hours.

## 8. Lock the complete OCaml dependency state

- **Scope:** Record a reproducible opam dependency solution/repository snapshot
  and toolchain prerequisites without duplicating `dune-project` dependency lists.
- **Rationale:** OCaml/wasm-tools/npm selections are pinned or locked, but most
  opam library versions are resolved from a changing repository. Existing-switch
  verification is not a reproducible clean bootstrap guarantee.
- **Dependencies:** None.
- **Acceptance criteria:** A clean project-local switch reproduces the documented
  solution and Wasm corpus hashes; generated opam metadata stays derived from
  Dune. No global installs, host-cache writes, or hidden SDK changes are needed.
- **Effort:** 16 hours.

## 9. Run an actual platform and engine matrix

- **Scope:** Verify clean native builds on macOS/Linux and ARM64/x86_64 where
  runners exist; test supported Node versions and Chromium/Firefox/WebKit with
  explicit Wasm-tail-call capability checks.
- **Rationale:** Setup mocks cover four asset selections, but current native and
  browser evidence is macOS/ARM64 plus one Chromium engine. A mobile viewport is
  not a real-device or Safari test.
- **Dependencies:** 8.
- **Acceptance criteria:** Retained owner-run results distinguish actual execution
  from mocks and unsupported capabilities. Every supported cell runs corpus/GC
  checks; unavailable cells are visibly unverified, not green skipped tests.
  Runner prerequisites are read-only or project-local.
- **Effort:** 12 hours.

## 10. Make standalone onboarding and full verification reproducible

- **Scope:** Provide documented repository-local environment initialization and a
  unified native/site/unit/browser check entry point, preserving explicit caller
  environment settings and strict missing-tool failures.
- **Rationale:** `scripts/env.sh` intentionally rejects ordinary external HOME/
  cache paths; current instructions assume a supplied local environment. Native
  `scripts/check.sh` alone does not execute npm/browser verification.
- **Dependencies:** 8, 9.
- **Acceptance criteria:** A fresh checkout following documented commands reaches
  all required gates without profile edits or global installation. Tests cover
  paths with spaces, existing settings, missing browsers/tools, and cleanup; a
  partial check never reports full verification.
- **Effort:** 12 hours.

## 11. Characterize post-GC performance and retention

- **Scope:** Measure allocation rates, collection counts/pause distributions,
  high-water/live distinctions, and root-frame costs across the five existing
  benchmarks using repeated, interleaved runs and explicit noise controls.
- **Rationale:** The current-GC replay passes all thirty configurations, but the
  committed optimization table is historical pre-GC data. Functional replay and
  one shared-host timing sample are not regression budgets or latency guarantees.
- **Dependencies:** 1, 8, 9.
- **Acceptance criteria:** Publish reproducible current-ABI results with samples,
  tool/host facts, and uncertainty. Retain historical observations separately;
  identical binaries are not credited with optimizer speedups. Thresholds use
  justified baselines rather than opportunistic timing values.
- **Effort:** 12 hours.

## 12. Version and test the embedding ABI

- **Scope:** Specify/version value/header/root APIs, host ownership, reentrancy,
  borrowed-memory lifetimes, and failed-instance disposal; add executable examples.
- **Rationale:** The 16-byte GC header and explicit host rooting are documented,
  but there is no negotiated ABI version or comprehensive embedding compatibility
  gate. Raw Wasm memory mutation remains outside the typed-language guarantee.
- **Dependencies:** 1, 3.
- **Acceptance criteria:** A pinned JS embedding example survives forced GC and
  memory growth, detects ABI mismatch, and rejects invalid root lifetimes and
  unsupported reuse. Native/browser documentation describes the same contract.
- **Effort:** 10 hours.

## 13. Complete owner-approved publication and legal metadata

- **Scope:** Finish license/provenance and maintainer/authorship/homepage/bug-report
  fields in source metadata, regenerate the opam file, and validate a local source
  distribution. Publishing remains an owner-controlled operation.
- **Rationale:** `opam lint` currently reports error 23 (maintainer) and warnings
  25/35/36/68. Native test success does not make the package release-ready. Owner
  identity and repository URLs must not be invented.
- **Dependencies:** 8, 9, 10, 12; owner-approved facts.
- **Acceptance criteria:** Lint has no errors and all remaining warnings are
  resolved or explicitly justified; license/attributions and generated metadata
  agree. A clean local distribution passes its declared checks. No credentials,
  remote publication, or global configuration are needed for repository checks.
- **Effort:** 8 hours.

## 14. Reduce conservative root retention and leaf-call overhead

- **Scope:** Add verified liveness-based root clearing and narrowly proven
  non-allocating leaf optimizations; do not introduce a moving/generational GC.
- **Rationale:** Rooting all named locals until function exit is safe but can
  retain dead graphs and adds frame traffic. Optimize only after measuring and
  strengthening safepoint verification.
- **Dependencies:** 1, 7, 11, 12, 13.
- **Acceptance criteria:** Forced-GC/model/corpus tests stay green under every
  pass; retained memory/frame work improves on a documented workload without
  changing output, trap order, or tail-call bounds. No unsupported speedup claims.
- **Effort:** 20 hours.

## 15. Add a small, specified string/int utility surface

- **Scope:** Consider only byte-string length and signed int32-to-string conversion,
  with consistent schemes, interpreter behavior, Wasm helpers, and browser support.
- **Rationale:** These make examples/diagnostics more ergonomic, but are new
  functionality and must not displace remaining correctness/release work.
- **Dependencies:** 4, 7, 12, 13.
- **Acceptance criteria:** Semantics specify bytes versus Unicode units and
  min-int formatting; all engines, GC safepoints, inferred schemes, error paths,
  and existing examples agree. No unrelated standard-library/module expansion.
- **Effort:** 16 hours.

## 16. Expose a stable machine-readable checking interface

- **Scope:** Add versioned structured check diagnostics/types for CLI consumers
  and align the browser bridge schema; defer a full language server or daemon.
- **Rationale:** Human-readable diagnostics and a private browser object protocol
  exist, but editor/tool integrations should not scrape terminal text. This is a
  later ergonomic feature, not a prerequisite for current compilation.
- **Dependencies:** 4, 12, 13.
- **Acceptance criteria:** Documented JSON schemas preserve severity, byte spans,
  labels, notes, and stable type names; Unicode/failure snapshots round-trip.
  Human CLI output remains compatible and source stdout is never mixed with
  diagnostic transport.
- **Effort:** 12 hours.
