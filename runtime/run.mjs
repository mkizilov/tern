import { readFile } from 'node:fs/promises';
import { existsSync, realpathSync, writeSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

function stdout(bytes) {
  let offset = 0;
  while (offset < bytes.length) {
    const written = writeSync(1, bytes, offset, bytes.length - offset);
    if (written === 0) throw new Error('stdout made no progress');
    offset += written;
  }
}

function i32(value) {
  if (!Number.isInteger(value) || value < -2147483648 || value > 2147483647) {
    throw new TypeError('printing imports require signed i32 arguments');
  }
  return value;
}

export async function instantiate(bytes, { write = stdout } = {}) {
  let instance;
  const imports = {
    tern: {
      print_int(value) {
        write(Buffer.from(String(i32(value))));
      },
      print_string(pointer, length) {
        const memory = instance?.exports.memory;
        if (!(memory instanceof WebAssembly.Memory)) {
          throw new Error('printing requires exported memory; call _start after instantiation');
        }
        const data = new Uint8Array(memory.buffer);
        const start = i32(pointer) >>> 0;
        const size = i32(length) >>> 0;
        if (start > data.length || size > data.length - start) {
          throw new RangeError('print_string range is outside linear memory');
        }
        // Copy exact bytes; neither UTF-8 decoding nor a stale buffer survives growth.
        write(Buffer.from(data.subarray(start, start + size)));
      },
    },
  };
  ({ instance } = await WebAssembly.instantiate(bytes, imports));
  if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error('module must export memory');
  }
  return instance;
}

export async function run(filename) {
  const instance = await instantiate(await readFile(filename));
  if (typeof instance.exports._start !== 'function') {
    throw new Error('module must export _start');
  }
  instance.exports._start();
}

if (process.argv[1] && existsSync(process.argv[1]) && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  if (process.argv.length !== 3) {
    process.stderr.write('Usage: node runtime/run.mjs FILE.wasm\n');
    process.exitCode = 2;
  } else {
    try {
      await run(process.argv[2]);
    } catch (error) {
      process.stderr.write(`runtime error: ${error.message}\n`);
      process.exitCode = 1;
    }
  }
}
