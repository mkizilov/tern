Compiled roots preserve escaping captures while allocating far beyond the actual heap.

  $ for flags in '' '--opt-all'; do
  >   ternc build $flags ../tests/stress/gc.tern -o gc.wasm || exit 1
  >   node --input-type=module - gc.wasm <<'JS' || exit 1
  > import assert from 'node:assert/strict';
  > import { readFileSync } from 'node:fs';
  > import { instantiate } from '../runtime/run.mjs';
  > const output = [];
  > const instance = await instantiate(readFileSync(process.argv[2]), { write: bytes => output.push(bytes) });
  > const r = instance.exports;
  > r._start();
  > assert.equal(Buffer.concat(output).toString(), '42\n');
  > assert.ok(r.rt_allocated_bytes() > 256n * 1024n * 1024n);
  > assert.ok(r.rt_gc_collections() > 1000);
  > assert.equal(r.memory.buffer.byteLength, 65536);
  > r.rt_collect();
  > assert.equal(r.rt_heap_top(), r.rt_heap_base.value);
  > console.log('GC: over 256 MiB allocated, one-page memory, captures survive, all roots released');
  > JS
  > done
  GC: over 256 MiB allocated, one-page memory, captures survive, all roots released
  GC: over 256 MiB allocated, one-page memory, captures survive, all roots released

The collector traces a live graph iteratively and grows only when retention requires it.

  $ ternc build ../tests/stress/live_graph.tern -o graph.wasm
  $ node --input-type=module - graph.wasm <<'JS'
  > import assert from 'node:assert/strict';
  > import { readFileSync } from 'node:fs';
  > import { instantiate } from '../runtime/run.mjs';
  > const output = [];
  > const instance = await instantiate(readFileSync(process.argv[2]), { write: bytes => output.push(bytes) });
  > const r = instance.exports;
  > r._start();
  > assert.equal(Buffer.concat(output).toString(), '200010000\n');
  > assert.ok(r.memory.buffer.byteLength > 65536);
  > assert.ok(r.memory.buffer.byteLength < 4 * 1024 * 1024);
  > assert.ok(r.rt_gc_collections() > 0);
  > r.rt_collect();
  > assert.equal(r.rt_heap_top(), r.rt_heap_base.value);
  > console.log('20,000 live list nodes survive collection; iterative mark and frame cleanup verified');
  > JS
  20,000 live list nodes survive collection; iterative mark and frame cleanup verified
