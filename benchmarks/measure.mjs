import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { instantiate } from '../runtime/run.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const compiler = resolve(process.argv[2] ?? join(root, '_build/default/bin/ternc.exe'));
if (!global.gc) throw new Error('run with node --expose-gc --max-old-space-size=256');
const scratch = mkdtempSync(join(process.env.TMPDIR ?? join(root, '.agent-local/tmp'), 'tern-bench-'));
const configurations = [
  ['baseline', []], ['constants', ['--const-fold']], ['dce', ['--dce']],
  ['inline', ['--inline']], ['matches', ['--match-simplify']], ['all', ['--opt-all']],
];
const programs = ['fibonacci', 'list_sort', 'tree_map', 'string_build', 'closures'];
const results = [];
let maxRss = 0;

async function sample(bytes, expected) {
  global.gc();
  const chunks = [];
  const instance = await instantiate(bytes, { write: chunk => chunks.push(chunk) });
  const start = process.hrtime.bigint();
  instance.exports._start();
  const milliseconds = Number(process.hrtime.bigint() - start) / 1e6;
  assert.deepEqual(Buffer.concat(chunks), expected);
  maxRss = Math.max(maxRss, process.memoryUsage().rss);
  return { milliseconds, heap: instance.exports.rt_heap_top() - instance.exports.rt_heap_base.value, memory: instance.exports.memory.buffer.byteLength };
}

try {
  for (const program of programs) {
    const source = join(root, 'benchmarks', `${program}.tern`);
    const expected = execFileSync(compiler, ['run', '--interp', source]);
    const variants = configurations.map(([configuration, flags]) => {
      const filename = join(scratch, `${program}-${configuration}.wasm`);
      execFileSync(compiler, ['build', ...flags, source, '-o', filename]);
      const bytes = readFileSync(filename);
      return { configuration, bytes, samples: [] };
    });
    for (let round = 0; round < 9; round++) {
      for (let offset = 0; offset < variants.length; offset++) {
        const variant = variants[(round + offset) % variants.length];
        const observation = await sample(variant.bytes, expected);
        if (round >= 2) variant.samples.push(observation);
      }
    }
    for (const { configuration, bytes, samples } of variants) {
      const times = samples.map(sample => sample.milliseconds).sort((a, b) => a - b);
      results.push({ program, configuration, hash: createHash('sha256').update(bytes).digest('hex'), size: bytes.length, time: times[3],
        heap: Math.max(...samples.map(sample => sample.heap)), memory: Math.max(...samples.map(sample => sample.memory)) });
    }
  }
  console.log('# IR optimization measurements\n');
  console.log(`Observed on ${process.version}, ${process.platform}/${process.arch}; ${execFileSync('wasm-tools', ['--version'], { encoding: 'utf8' }).trim()}.`);
  console.log('Compiler: project-local OCaml 5.4.1. Five fixed programs, six configurations. Each cell is validated and checked against AST stdout.\n');
  console.log('## Method\n');
  console.log('Inputs: naive Fibonacci(24); insertion sort of a descending 300-element list plus order-sensitive checksum; persistent binary-search-tree insertion of 1,000 permuted keys and lookup sum; 4,000 string appends (8,000 output bytes plus LF); 10,000 closure-heavy iterations with option wrapping and a small helper.');
  console.log('Each configuration starts from the same checked source. Baseline disables every pass; each individual column enables only that pass; all uses inline → constants → matches → DCE. Flags are opt-in and default off.');
  console.log('Runtime is median of 7 fresh-instance `_start` executions after 2 warmups. Configurations are interleaved per round with rotating order. Building/instantiation/host GC are excluded; output capture and Tern GC pauses are included. Node host GC runs before each sample. The managed-heap column is the ending high-water cursor after the last collection, not peak allocation or live bytes.');
  console.log('The host uses `--max-old-space-size=256`; each Wasm instance is capped at 64 MiB. Measurements are sequential. Timing differences near timer/JIT noise are not speedup claims.\n');
  console.log('| Program | Pass | Wasm bytes | Median ms | Size Δ | Time Δ | Same binary as baseline | Ending managed bytes | Linear bytes |');
  console.log('| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |');
  for (const result of results) {
    const baseline = results.find(row => row.program === result.program && row.configuration === 'baseline');
    const delta = (value, original) => `${((value / original - 1) * 100).toFixed(1)}%`;
    console.log(`| ${result.program} | ${result.configuration} | ${result.size} | ${result.time.toFixed(4)} | ${delta(result.size, baseline.size)} | ${delta(result.time, baseline.time)} | ${result.hash === baseline.hash ? 'yes' : 'no'} | ${result.heap} | ${result.memory} |`);
  }
  console.log(`\nMaximum sampled ending host RSS: ${maxRss} bytes (not a continuous peak measurement). No generated dataset is retained; build artifacts are removed in finally.\n`);
  console.log('## Reproduce\n\n```sh\nscripts/check.sh\nPATH="$PWD/.tools/bin:$PATH" node --expose-gc --max-old-space-size=256 benchmarks/measure.mjs > OPTIMIZATIONS.md\n```\n');
  console.log('## Scope and safety\n');
  console.log('Constant folding/propagation uses int32 semantics and leaves invalid division/remainder to trap at runtime. DCE removes unused total values/functions and unreachable case actions while retaining calls, tuple/constructor/concat operations, projections, and arithmetic traps. Inlining copies small non-recursive bodies with fresh identities; it is not recursive unrolling. Known-constructor simplification selects proven decision arms and safe projections without dropping subject effects.');
  console.log('None of these passes guarantees lower runtime or smaller output in every program. The complete hand-written runtime remains embedded, so IR reductions can be small relative to runtime bytes. Each pass is independently tested and the all-enabled pipeline is covered by AST/IR/Wasm differential properties. Resource-exhaustion timing is not an optimization equivalence guarantee.');
  console.log('Rows with identical SHA-256 binary content still vary in measured time: those differences are host/JIT/order noise, not optimizer improvements. Constant propagation can also duplicate literal construction at use sites; lower binary size does not guarantee fewer allocations (see string building).');
  console.log('An earlier batched trial showed a 62.4% apparent list-sort slowdown for identical bytes. That observation prompted interleaved rounds for the final table; even interleaving does not isolate the shared host or justify significance claims.');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
