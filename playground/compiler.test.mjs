import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';
import { assemble, execute } from './execution.js';
import { editorDiagnostics } from './spans.js';

const context = createContext({ console, TextEncoder, TextDecoder, setTimeout, clearTimeout, performance });
runInContext(readFileSync('site/compiler.js', 'utf8'), context, { timeout: 10000 });
const compiler = context.TernCompiler;

test('the actual js_of_ocaml compiler and wabt execute every golden example byte-for-byte', async () => {
  const files = readdirSync('examples').filter(file => file.endsWith('.tern')).sort();
  assert.equal(files.length, 16);
  for (const file of files) {
    const result = compiler.compile(readFileSync(`examples/${file}`, 'utf8'));
    assert.equal(result.ok, true, file);
    assert.ok(result.ir.length && result.wat.includes('(module'), file);
    const chunks = [];
    await execute(await assemble(result.wat), bytes => chunks.push(Buffer.from(bytes)));
    assert.deepEqual(Buffer.concat(chunks), readFileSync(`examples/${file.replace('.tern', '.out')}`), file);
  }
});

test('every example survives collection before every allocation, including root-frame allocation', async () => {
  const needle = '(local.set $pointer (call $find_free (local.get $total)))';
  for (const file of readdirSync('examples').filter(file => file.endsWith('.tern')).sort()) {
    const result = compiler.compile(readFileSync(`examples/${file}`, 'utf8'));
    assert.equal(result.ok, true, file);
    assert.ok(result.wat.includes(needle));
    const wat = result.wat.replace(needle, `(call $rt_collect)\n${needle}`);
    const chunks = [];
    await execute(await assemble(wat), bytes => chunks.push(Buffer.from(bytes)));
    assert.deepEqual(Buffer.concat(chunks), readFileSync(`examples/${file.replace('.tern', '.out')}`), file);
  }
});

test('UTF-8 compiler spans map to UTF-16 editor offsets after astral characters and CRLF', () => {
  const source = 'let feather = "🪶é";;\r\nlet bad = 1 + true;;';
  const result = compiler.compile(source);
  assert.equal(result.ok, false);
  const [error] = editorDiagnostics(source, result.diagnostics);
  assert.equal(error.from, source.indexOf('true'));
  assert.equal(error.to, source.indexOf('true') + 4);
  assert.match(result.diagnostics[0].rendered, /playground\.tern:2:15/);
});

test('secondary labels and EOF diagnostics retain their actual ranges', () => {
  const duplicate = 'let (x, x) = (1, 2);;';
  const result = compiler.compile(duplicate);
  const mapped = editorDiagnostics(duplicate, result.diagnostics);
  assert.equal(mapped.length, 2);
  assert.equal(duplicate.slice(mapped[0].from, mapped[0].to), 'x');
  assert.equal(duplicate.slice(mapped[1].from, mapped[1].to), 'x');
  assert.notEqual(mapped[0].from, mapped[1].from);
  const eof = 'let x =';
  const [error] = editorDiagnostics(eof, compiler.compile(eof).diagnostics);
  assert.equal(error.from, eof.length);
  assert.equal(error.to, eof.length);
});

test('browser-host execution preserves output preceding a runtime trap', async () => {
  const compiled = compiler.compile('let () = print_string "before"; print_int (1 / 0);;');
  assert.equal(compiled.ok, true);
  const chunks = [];
  await assert.rejects(execute(await assemble(compiled.wat), bytes => chunks.push(Buffer.from(bytes))), WebAssembly.RuntimeError);
  assert.equal(Buffer.concat(chunks).toString(), 'before');
});

test('the browser host rejects out-of-bounds print requests', async () => {
  const binary = await assemble('(module (import "tern" "print_string" (func $print (param i32 i32))) (memory (export "memory") 1) (func (export "_start") i32.const 65535 i32.const 2 call $print))');
  await assert.rejects(execute(binary, () => assert.fail('invalid bytes reached output')), /outside Wasm memory/);
});

test('the README language-tour programs compile and execute', async () => {
  const programs = [...readFileSync('README.md', 'utf8').matchAll(/```ocaml\n([\s\S]*?)```/g)];
  assert.equal(programs.length, 2);
  for (let i = 0; i < programs.length; i++) {
    const result = compiler.compile(programs[i][1]);
    assert.equal(result.ok, true);
    const chunks = [];
    await execute(await assemble(result.wat), bytes => chunks.push(Buffer.from(bytes)));
    assert.equal(Buffer.concat(chunks).toString(), i === 0 ? '42\n' : '');
  }
});
