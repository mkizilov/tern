import { assemble, execute } from './execution.js';

importScripts('compiler.js');

self.onmessage = async ({ data: source }) => {
  try {
    if (new TextEncoder().encode(source).length > 256 * 1024) {
      throw new Error('Source exceeds the 256 KiB playground limit.');
    }
    const result = self.TernCompiler.compile(source);
    self.postMessage({ kind: 'compiled', result });
    if (!result.ok) {
      self.postMessage({ kind: 'done', success: false });
      return;
    }
    const binary = await assemble(result.wat);
    let written = 0;
    await execute(binary, bytes => {
      written += bytes.length;
      if (written > 64 * 1024) throw new Error('Output exceeds the 64 KiB playground limit.');
      self.postMessage({ kind: 'output', bytes }, [bytes.buffer]);
    });
    self.postMessage({ kind: 'done', success: true });
  } catch (error) {
    self.postMessage({ kind: 'done', success: false, error: String(error) });
  }
};
