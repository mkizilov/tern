import wabtFactory from 'wabt';

let toolkit;
export async function assemble(wat) {
  const wabt = await (toolkit ??= wabtFactory());
  const module = wabt.parseWat('playground.wat', wat, { tail_call: true });
  try {
    module.resolveNames();
    module.validate({ tail_call: true });
    return module.toBinary({ canonicalize_lebs: true, write_debug_names: true }).buffer;
  } finally {
    module.destroy();
  }
}

export async function execute(bytes, write) {
  const encoder = new TextEncoder();
  let instance;
  ({ instance } = await WebAssembly.instantiate(bytes, {
    tern: {
      print_int(value) { write(encoder.encode(String(value))); },
      print_string(pointer, length) {
        pointer >>>= 0;
        length >>>= 0;
        const memory = instance.exports.memory.buffer;
        if (pointer > memory.byteLength || length > memory.byteLength - pointer) {
          throw new RangeError('print_string is outside Wasm memory');
        }
        write(new Uint8Array(memory, pointer, length).slice());
      },
    },
  }));
  instance.exports._start();
}
