import { build, transform } from 'esbuild';
import { copyFileSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const site = resolve('site');
mkdirSync(site, { recursive: true });
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
const examples = readdirSync('examples').filter(name => name.endsWith('.tern')).sort().map(file => ({
  file, title: file.replace('.tern', '').replaceAll('_', ' '),
  source: readFileSync(`examples/${file}`, 'utf8'),
}));
writeFileSync(`${site}/examples.json`, JSON.stringify(examples));
console.log(`Built site/ with ${examples.length} examples; no server-side compiler required.`);
