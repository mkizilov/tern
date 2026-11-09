import { build, transform } from 'esbuild';
import { copyFileSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const site = resolve('site');
mkdirSync(site, { recursive: true });
mkdirSync(`${site}/licenses`, { recursive: true });
await build({
  entryPoints: ['playground/app.js', 'playground/worker.js'], outdir: site,
  bundle: true, minify: true, platform: 'browser', target: 'es2022', format: 'iife',
  external: ['fs'], // wabt's Node-only branch is unreachable in a browser worker.
  logLevel: 'info',
});
const compiler = await transform(readFileSync('_build/default/playground/compiler.bc.js', 'utf8'), {
  minify: true, target: 'es2022',
});
writeFileSync(`${site}/compiler.js`, compiler.code);
copyFileSync('playground/index.html', `${site}/index.html`);
copyFileSync('playground/app.css', `${site}/app.css`);
for (const file of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) copyFileSync(file, `${site}/${file}`);
for (const file of readdirSync('licenses')) copyFileSync(`licenses/${file}`, `${site}/licenses/${file}`);
const escape = text => text.replace(/[&<>\"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[character]);
const legalFiles = ['LICENSE', 'THIRD_PARTY_NOTICES.md', ...readdirSync('licenses').sort().map(file => `licenses/${file}`)];
writeFileSync(`${site}/notices.html`, `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>License notices · Tern</title><link rel="stylesheet" href="app.css"><main><a href="index.html">Back to playground</a><h1>License notices</h1>${legalFiles.map(file => `<h2>${escape(file)}</h2><pre style="white-space:pre-wrap;overflow-wrap:anywhere">${escape(readFileSync(file, 'utf8'))}</pre>`).join('')}</main></html>`);
const examples = readdirSync('examples').filter(name => name.endsWith('.tern')).sort().map(file => ({
  file, title: file.replace('.tern', '').replaceAll('_', ' '),
  source: readFileSync(`examples/${file}`, 'utf8'),
}));
writeFileSync(`${site}/examples.json`, JSON.stringify(examples));
console.log(`Built site/ with ${examples.length} examples; no server-side compiler required.`);
