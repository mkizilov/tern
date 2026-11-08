import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, rmdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';

const temporaryRoot = process.env.TMPDIR ?? resolve('.agent-local/tmp');
const existing = new Set(readdirSync(temporaryRoot));
const directory = mkdtempSync(`${temporaryRoot}/tern-ui-test-`);
try {
  execFileSync(process.execPath, ['node_modules/@playwright/test/cli.js', 'test', '--config', 'playground/playwright.config.mjs', '--output', directory], {
    stdio: 'inherit',
    env: {
      ...process.env,
      PLAYWRIGHT_BROWSERS_PATH: process.env.PLAYWRIGHT_BROWSERS_PATH ?? resolve('.agent-local/browsers'),
      PLAYWRIGHT_TRANSFORM_CACHE_DIR: process.env.PLAYWRIGHT_TRANSFORM_CACHE_DIR ?? join(directory, 'transform'),
    },
  });
} catch (error) {
  process.exitCode = error.status ?? 1;
} finally {
  rmSync(directory, { recursive: true, force: true });
  // Chromium removes profile contents but leaves empty roots on this host.
  for (const name of readdirSync(temporaryRoot)) {
    if (!existing.has(name) && name.startsWith('playwright_chromiumdev_profile-')) {
      rmdirSync(join(temporaryRoot, name));
    }
  }
}
