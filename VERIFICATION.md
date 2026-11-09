# Verification scope and evidence

Reviewed on **2026-11-08**, against implementation baseline `290fbf3`. This is a
maintained verification guide, not a claim of complete correctness or a security
certification. `ROADMAP.md` lists work not yet implemented. `DESIGN.md` retains
historical development observations; this document states the current evidence.

## Status vocabulary

- **Implemented:** the code path exists; this alone does not establish coverage.
- **Verified:** named checks were actually executed on the environment below.
- **Partial:** only a bounded subset, limited contract, or selected environment is
  covered; remaining gaps are explicit.
- **Unverified:** no execution evidence is claimed for the named behavior/platform.

## Current implementation and limits

| Area | Implemented / verified evidence | Partial or unverified behavior |
| --- | --- | --- |
| Front end and HM inference | Located lexer/parser, resolver, inference, type printing, phase expectations, and all 16 examples | Tests are not a proof over all programs; adversarial compiler work/memory is not explicitly budgeted in every phase |
| Pattern analysis | Typed usefulness, redundancy, and missing-witness tests, including nested list/option cases | Conservative treatment of uninhabited recursive types; broader witness/model verification remains |
| Interpreters and backend | AST/ANF/closed interpreters; full-language WAT; direct/indirect tail calls; exact golden corpus | QCheck generation is bounded and excludes some language/resource families, including recursive/string generation |
| Optimizations | Four independent opt-in passes, individual/all-enabled corpus checks, typed randomized comparisons | Not universal size/speed improvements; no exhaustive equivalence proof |
| Collector | Mark-sweep, shadow roots, iterative cyclic tracing, coalescing, helper safepoints, OOM and stress assertions | Conservative local retention, fragmentation, manual host rooting, and discard-after-trap contract; no compaction or trap unwinder |
| Runtime errors | Front-end errors have rendered real spans; runtime failures retain prior output | Compiled runtime traps are not source-mapped; generic Wasm traps do not expose a full fault taxonomy |
| Playground | Real js_of_ocaml compiler, wabt assembly, worker execution, same-origin static GETs, Unicode highlights, limits, cancellation, and viewport tests | Chromium only; Safari/Firefox, actual mobile devices, and hard JS-worker heap isolation are unverified |
| Setup | Existing macOS/ARM64 switch works; offline mocks check platform asset selection, checksums, spaces, worker limits, and failure cleanup | Mocked Linux/x86 selections are not clean installations; ordinary external HOME/cache paths intentionally fail the local-state guard |
| Dependencies | Exact npm lock; pinned tool releases/checksums; npm audit reported zero known advisories | Most opam library versions are not locked to a repository snapshot; advisory absence is not a source/engine security audit |
| Publication | Dune-generated opam metadata and a local CLI/library build exist | **Blocked:** opam lint fails for maintainer metadata and reports additional publication-field warnings; no release-readiness claim |

The runtime host is not advertised as a hardened arbitrary-Wasm service. The
playground compiles typed Tern, exposes only printing imports, and uses a worker
deadline. An external embedder that mutates guest memory or retains unrooted raw
values is outside the typed-language safety contract.

## Reproducible checks

Run inside the repository with the documented local environment and installed
dependencies. Preserve supplied HOME/TMPDIR/cache/SDK settings. Do not use host
service sockets, global installs, or external caches to make a check pass.

```sh
scripts/check.sh
.tools/bin/opam exec --switch=. -- dune runtest --force --root . -j 2
scripts/build-site.sh
npm test
npm run test:browser
npm audit --json --cache "$XDG_CACHE_HOME/npm"
.tools/bin/opam lint ternc.opam
```

`scripts/check.sh` is the **native** build/test/format gate; it does not stand in
for the npm/browser commands. The forced native command reruns expectations,
Cram/runtime tests, and the default differential campaign instead of relying on
cached test actions. SDK selection is performed by repository scripts; manual
native rebuilding may also require the supplied read-only SDK setting.

Browser installation and fresh-checkout prerequisites are documented in README.
The supplied `PLAYWRIGHT_BROWSERS_PATH=0` uses project-local node_modules storage;
`npm ci` replaces that directory, so reinstall the browser afterward. A missing
browser is a failed/unverified browser check, not an automatic success.

Longer property replay is explicit:

```sh
TERN_DIFF_SEED=171717 TERN_DIFF_COUNT=500 scripts/check.sh
```

The generator prints feature counts and seeds. Keep minimized confirmed failures
as source fixtures; do not change expected output to conceal a mismatch.

## Review observations

The final native/site/JavaScript/Chromium checks are rerun for this review; their
scope is the local toolchain, not an unexecuted platform matrix. The suites cover:

- 32 offline infrastructure/document contracts, including roadmap field/dependency
  validation, estimate arithmetic, and preserved repository boundaries;
- 16 examples and five curated programs through AST/IR/Wasm, with baseline,
  individual passes, and every pass enabled;
- 150 cases per default execution property and 500 typed generation/shrink cases;
- 21 real-Wasm runtime tests, plus compiler phase/Cram tests, retained-live-data
  OOM, and a 10-million-step tail loop;
- both optimized and unoptimized two-million-iteration GC churn: more than
  256 MiB cumulative physical requests in exactly 64 KiB linear memory, with
  value-sensitive captures retained across collecting non-tail calls;
- a 20,000-node retained list, required growth, iterative tracing, and complete
  reclamation after the source invocation;
- seven generated-JavaScript tests, including all examples with collection forced
  before every allocation through the default non-optimized browser compiler,
  plus executable README tour snippets;
- eight real Chromium UI tests, including all dropdown examples, errors/warnings,
  partial runtime output, cancellation, limits, safe text, tab keys, edit races,
  and responsive viewport layout.

The current-GC benchmark runner was also replayed across **all 30 configurations**
(five programs × baseline/four individual passes/all). Every configuration
assembled, validated, and matched actual AST stdout. No transient output report
was retained. This functional replay is not isolated performance/latency evidence;
`OPTIMIZATIONS.md` remains explicitly historical pre-GC data. The runner's current
managed-byte metric is an ending cursor, not peak or live bytes.

`npm audit --json` returned zero known vulnerabilities for the current locked
production/development dependency graph. The registry response is date-specific
and does not prove the compiler, browser engine, or dependencies are vulnerability-
free. No dependency update was justified by that result.

`opam lint ternc.opam` exited **1**: error 23 (missing maintainer), with warnings
25 (authors), 35 (homepage), 36 (bug-reports), and 68 (license). These publication
facts remain pending owner-approved work. They are not silently folded into a
passing native gate or filled with invented identities/URLs.

## Observed tools and unverified environments

| Tool / environment | Observed version or scope |
| --- | --- |
| OS/CPU | macOS / ARM64 |
| OCaml | 5.4.1, project-local switch |
| Dune | 3.24.2 |
| js_of_ocaml | 6.5.0 in the existing switch |
| wasm-tools | 1.263.0 (7a2fa422c, 2026-10-30) |
| Node / npm | v26.13.0 / 11.20.0 |
| Browser tooling | pinned Playwright 1.65.0 Chromium headless shell, one worker |

Fresh network bootstrap, Linux/x86_64 execution, other Node versions, Firefox,
WebKit/Safari, actual mobile devices, public deployment, publication, and isolated
performance benchmarks were **not verified here**. Docker/hardware/host-service
access is neither required nor exercised.

AFT lacks ocamllsp and uses a fallback JavaScript analyzer; its partial snapshot
is not an OCaml clean bill of health. Native compilation/tests and executed Wasm
are authoritative. Cram's occasional Perl classification is a tooling gap, not
a compiler diagnosis. Reachability/unused-export hints do not justify deletion.
Owned browser/server lifecycles and the closed loopback endpoint verify cleanup;
host-wide process enumeration is sandbox-restricted and is not bypassed.
