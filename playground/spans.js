export function editorDiagnostics(source, diagnostics) {
  const offsets = new Uint32Array(new TextEncoder().encode(source).length + 1);
  let byte = 0, unit = 0;
  for (const character of source) {
    const point = character.codePointAt(0);
    const length = point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4;
    offsets.fill(unit, byte, byte + length);
    byte += length;
    unit += character.length;
    offsets[byte] = unit;
  }
  const position = byte => offsets[Math.max(0, Math.min(offsets.length - 1, byte))];
  return diagnostics.flatMap(diagnostic => {
    const item = (span, message, severity) => ({
      from: position(span.startByte), to: position(span.endByte), message, severity,
    });
    return [
      item(diagnostic.primary, diagnostic.message, diagnostic.severity === 'note' ? 'info' : diagnostic.severity),
      ...diagnostic.secondary.map(label => item(label.span, label.message || 'Related location', 'info')),
    ];
  });
}
