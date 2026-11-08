import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { instantiate } from './run.mjs';

const directory = dirname(fileURLToPath(import.meta.url));
const temporary = process.env.TMPDIR ?? join(directory, '..', '.agent-local', 'tmp');
mkdirSync(temporary, { recursive: true });
const scratch = mkdtempSync(join(temporary, 'tern-runtime-'));
after(() => rmSync(scratch, { recursive: true, force: true }));
const wat = readFileSync(join(directory, 'runtime.wat'), 'utf8');
let sequence = 0;

function assemble(source) {
  const base = join(scratch, `fixture-${sequence++}`);
  writeFileSync(`${base}.wat`, source);
  const options = { env: { ...process.env, RAYON_NUM_THREADS: '2' } };
  execFileSync('wasm-tools', ['parse', `${base}.wat`, '-o', `${base}.wasm`], options);
  execFileSync('wasm-tools', ['validate', `${base}.wasm`], options);
  return { bytes: readFileSync(`${base}.wasm`), filename: `${base}.wasm` };
}

function fixture(tail) {
  return assemble(`${wat.trimEnd().slice(0, -1)}\n${tail}\n)`);
}

const runtime = assemble(wat);
async function fresh(bytes = runtime.bytes) {
  const output = [];
  const instance = await instantiate(bytes, { write: bytes => output.push(bytes) });
  return { r: instance.exports, output };
}

function string(r, bytes) {
  const data = Buffer.from(bytes);
  const value = r.rt_string(data.length);
  new Uint8Array(r.memory.buffer, r.rt_string_data(value), data.length).set(data);
  return value;
}

function bytes(r, value) {
  return Buffer.from(new Uint8Array(r.memory.buffer, r.rt_string_data(value), r.rt_string_length(value)));
}

const traps = operation => assert.throws(operation, WebAssembly.RuntimeError);

test('runtime has only printing imports and no automatic source entry', () => {
  const module = new WebAssembly.Module(runtime.bytes);
  assert.deepEqual(WebAssembly.Module.imports(module), [
    { module: 'tern', name: 'print_int', kind: 'function' },
    { module: 'tern', name: 'print_string', kind: 'function' },
  ]);
  assert.equal(WebAssembly.Module.exports(module).some(item => item.name === '_start'), false);
});

test('unboxed values retain every signed int32 bit and disjoint tags', async () => {
  const { r } = await fresh();
  for (const value of [-2147483648, -2147483647, -65536, -1, 0, 1, 65536, 2147483646, 2147483647]) {
    const encoded = r.rt_int(value);
    assert.equal(encoded, (BigInt(value) << 3n) | 1n);
    assert.equal(r.rt_unbox_int(encoded), value);
  }
  assert.equal(r.rt_bool(0), 2n);
  assert.equal(r.rt_bool(1), 10n);
  assert.equal(r.rt_unit.value, 3n);
  assert.equal(r.rt_unbox_bool(2n), 0);
  assert.equal(r.rt_unbox_bool(10n), 1);
  for (const bad of [0n, 2n, 3n, 10n, (1n << 50n) | 1n]) traps(() => r.rt_unbox_int(bad));
  for (const bad of [0n, 1n, 3n, 18n]) traps(() => r.rt_unbox_bool(bad));
  traps(() => r.rt_bool(-1));
  traps(() => r.rt_bool(2));
});

test('headers contain payload byte size, auxiliary word, and reserved GC bits', async () => {
  const { r } = await fresh();
  const tuple = r.rt_tuple(3);
  const pointer = r.rt_pointer(tuple);
  assert.equal(pointer % 8, 0);
  assert.equal(tuple, BigInt(pointer));
  const view = new DataView(r.memory.buffer);
  assert.equal(view.getUint32(pointer, true), (24 << 8) | 1);
  assert.equal(view.getUint32(pointer + 4, true), 0);
  view.setUint32(pointer, view.getUint32(pointer, true) | 0xc0, true);
  assert.equal(r.rt_kind(tuple), 1);
  assert.equal(r.rt_size(tuple), 24);
  assert.equal(r.rt_field_get(tuple, 0), 3n);
});

test('tuple and environment fields are initialized, indexed, and independent', async () => {
  const { r } = await fresh();
  const tuple = r.rt_tuple(2);
  const environment = r.rt_environment(2);
  assert.equal(r.rt_kind(environment), 5);
  for (const value of [tuple, environment]) {
    assert.equal(r.rt_field_get(value, 0), 3n);
    assert.equal(r.rt_field_set(value, 0, r.rt_int(42)), 3n);
    r.rt_field_set(value, 1, r.rt_bool(1));
    assert.equal(r.rt_unbox_int(r.rt_field_get(value, 0)), 42);
    assert.equal(r.rt_field_get(value, 1), 10n);
    traps(() => r.rt_field_get(value, -1));
    traps(() => r.rt_field_get(value, 2));
    traps(() => r.rt_field_set(value, 2, 3n));
  }
  r.rt_field_set(tuple, 0, r.rt_int(7));
  assert.equal(r.rt_unbox_int(r.rt_field_get(environment, 0)), 42);
  assert.equal(r.rt_size(r.rt_environment(0)), 0);
  traps(() => r.rt_tuple(1));
  traps(() => r.rt_environment(-1));
});

test('variants distinguish constructor identity from block kind and payload count', async () => {
  const { r } = await fresh();
  const none = r.rt_variant_nullary(17);
  const some = r.rt_variant(18, r.rt_int(-2147483648));
  assert.equal(r.rt_kind(none), 2);
  assert.equal(r.rt_variant_tag(none), 17);
  assert.equal(r.rt_size(none), 0);
  assert.equal(r.rt_variant_tag(some), 18);
  assert.equal(r.rt_size(some), 8);
  assert.equal(r.rt_unbox_int(r.rt_variant_payload(some)), -2147483648);
  traps(() => r.rt_variant_payload(none));
  traps(() => r.rt_variant_payload(r.rt_tuple(2)));
  traps(() => r.rt_field_set(some, 0, 3n));
});

test('closure records support tied recursive environments without lexical host closures', async () => {
  const { r } = await fresh();
  const environment = r.rt_environment(2);
  const even = r.rt_closure(4, environment);
  const odd = r.rt_closure(5, environment);
  r.rt_field_set(environment, 0, even);
  r.rt_field_set(environment, 1, odd);
  assert.equal(r.rt_kind(even), 3);
  assert.equal(r.rt_closure_code(even), 4);
  assert.equal(r.rt_closure_environment(even), environment);
  assert.equal(r.rt_field_get(r.rt_closure_environment(odd), 0), even);
  traps(() => r.rt_closure(0, r.rt_tuple(2)));
  traps(() => r.rt_closure_environment(BigInt(r.rt_alloc(3, 0, 0))));
});

test('closure ABI calls a Wasm table entry with explicit environment and i64 argument', async () => {
  const compiled = fixture(`
    (table 1 funcref)
    (func $identity (type $tern_function) (param $env i64) (param $x i64) (result i64)
      (local.get $x))
    (elem (i32.const 0) $identity)
    (func (export "invoke") (param $closure i64) (param $argument i64) (result i64)
      (call_indirect (type $tern_function)
        (call $rt_closure_environment (local.get $closure))
        (local.get $argument)
        (call $rt_closure_code (local.get $closure))))`);
  const { r } = await fresh(compiled.bytes);
  const closure = r.rt_closure(0, r.rt_environment(0));
  assert.equal(r.rt_unbox_int(r.invoke(closure, r.rt_int(2147483647))), 2147483647);
  traps(() => r.invoke(r.rt_closure(9, r.rt_environment(0)), r.rt_int(1)));
});

test('strings are exact byte sequences with no terminator or decoding', async () => {
  const { r } = await fresh();
  const source = Buffer.from('é😀\n\0');
  const value = string(r, source);
  assert.equal(r.rt_kind(value), 4);
  assert.equal(r.rt_string_length(value), source.length);
  assert.deepEqual(bytes(r, value), source);
  assert.equal(r.rt_size(r.rt_string(0)), 0);
  traps(() => r.rt_field_get(value, 0));
  traps(() => r.rt_string_length(r.rt_int(0)));
});

test('concatenation and literal equality preserve inputs and empty strings', async () => {
  const { r } = await fresh();
  const left = string(r, 'hello ');
  const right = string(r, '世界');
  const result = r.rt_string_concat(left, right);
  assert.deepEqual(bytes(r, result), Buffer.from('hello 世界'));
  assert.equal(r.rt_string_equal(result, string(r, 'hello 世界')), 10n);
  assert.equal(r.rt_string_equal(result, left), 2n);
  assert.equal(r.rt_string_equal(string(r, 'ab'), string(r, 'ac')), 2n);
  assert.equal(r.rt_string_equal(r.rt_string(0), r.rt_string(0)), 10n);
  assert.deepEqual(bytes(r, r.rt_string_concat(r.rt_string(0), right)), bytes(r, right));
  assert.deepEqual(bytes(r, left), Buffer.from('hello '));
});

test('growth preserves old objects and refreshes host memory views on each print', async () => {
  const { r, output } = await fresh();
  const before = string(r, 'before');
  const oldBuffer = r.memory.buffer;
  r.rt_string(131072);
  assert.notEqual(r.memory.buffer, oldBuffer);
  assert.deepEqual(bytes(r, before), Buffer.from('before'));
  assert.equal(r.rt_print_string(before), 3n);
  const after = string(r, Buffer.from([0xff, 0, 0x80]));
  r.rt_print_string(after);
  new Uint8Array(r.memory.buffer)[r.rt_string_data(before)] = 88;
  assert.deepEqual(Buffer.concat(output), Buffer.concat([Buffer.from('before'), Buffer.from([0xff, 0, 0x80])]));
});

test('print helpers write signed decimal and raw bytes without implicit newlines', async () => {
  const { r, output } = await fresh();
  assert.equal(r.rt_print_int(r.rt_int(-2147483648)), 3n);
  r.rt_print_string(string(r, '\né\n'));
  r.rt_print_int(r.rt_int(2147483647));
  assert.deepEqual(Buffer.concat(output), Buffer.from('-2147483648\né\n2147483647'));
});

test('allocation rejects invalid sizes and leaves heap state unchanged on bounded OOM', async () => {
  const { r } = await fresh();
  const start = r.rt_heap_top();
  for (const [kind, size] of [[0, 0], [6, 0], [1, -1], [4, 16777216], [1, 0x7fffffff]]) {
    traps(() => r.rt_alloc(kind, size, 0));
    assert.equal(r.rt_heap_top(), start);
  }
  for (let i = 0; i < 3; i++) r.rt_string(16777215);
  const full = r.rt_heap_top();
  traps(() => r.rt_string(16777215));
  assert.equal(r.rt_heap_top(), full);
  assert.ok(r.memory.buffer.byteLength <= 64 * 1024 * 1024);
  const small = r.rt_tuple(2);
  assert.equal(r.rt_field_get(small, 0), 3n);
});

test('pointer validation rejects immediates, null, misalignment and out-of-heap values', async () => {
  const { r } = await fresh();
  const value = r.rt_tuple(2);
  for (const bad of [0n, 1n, 2n, 3n, value + 1n, -8n, 1n << 40n, BigInt(r.rt_heap_top())]) {
    traps(() => r.rt_pointer(bad));
  }
  assert.equal(r.rt_pointer(value), Number(value));
});

function cli(filename) {
  return spawnSync(process.execPath, [join(directory, 'run.mjs'), filename], { encoding: null });
}

test('real Node runner instantiates and invokes a hand-written _start fixture', () => {
  const compiled = fixture(`
    (data (i32.const 64) "\\c3\\a9\\0a")
    (func (export "_start") (local $text i64)
      (drop (call $rt_print_int (call $rt_int (i32.const -2147483648))))
      (local.set $text (call $rt_string (i32.const 3)))
      (memory.copy (call $rt_string_data (local.get $text)) (i32.const 64) (i32.const 3))
      (drop (call $rt_print_string (local.get $text))))`);
  const result = cli(compiled.filename);
  assert.equal(result.status, 0, result.stderr.toString());
  assert.deepEqual(result.stdout, Buffer.from('-2147483648é\n'));
  assert.equal(result.stderr.length, 0);
});

test('runner errors preserve partial stdout and return nonzero separately on stderr', () => {
  const compiled = fixture(`
    (func (export "_start")
      (drop (call $rt_print_int (call $rt_int (i32.const 42))))
      unreachable)`);
  const result = cli(compiled.filename);
  assert.equal(result.status, 1);
  assert.deepEqual(result.stdout, Buffer.from('42'));
  assert.match(result.stderr.toString(), /^runtime error:/);
});

test('runner checks imported memory ranges and required exports', async () => {
  const invalid = assemble(`(module
    (import "tern" "print_string" (func $print (param i32 i32)))
    (memory (export "memory") 1)
    (func (export "_start") (call $print (i32.const 65535) (i32.const 2))))`);
  const range = cli(invalid.filename);
  assert.equal(range.status, 1);
  assert.equal(range.stdout.length, 0);
  assert.match(range.stderr.toString(), /outside linear memory/);
  const wrongAbi = assemble(`(module
    (import "tern" "print_int" (func $print (param i64)))
    (memory (export "memory") 1)
    (func (export "_start") (call $print (i64.const 42))))`);
  const wrong = cli(wrongAbi.filename);
  assert.equal(wrong.status, 1);
  assert.equal(wrong.stdout.length, 0);
  assert.match(wrong.stderr.toString(), /require signed i32 arguments/);
  const missing = assemble('(module (func (export "_start")))');
  await assert.rejects(instantiate(missing.bytes), /export memory/);
  assert.equal(cli(runtime.filename).status, 1);
  const usage = spawnSync(process.execPath, [join(directory, 'run.mjs')]);
  assert.equal(usage.status, 2);
  assert.equal(usage.stdout.length, 0);
});
