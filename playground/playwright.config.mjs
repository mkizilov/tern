import { defineConfig } from '@playwright/test';
import { fileURLToPath } from 'node:url';

export default defineConfig({
  testDir: '.',
  testMatch: 'browser.spec.mjs',
  workers: 1,
  retries: 0,
  timeout: 60000,
  reporter: 'list',
  use: { baseURL: 'http://127.0.0.1:21916', viewport: { width: 1280, height: 920 } },
  webServer: {
    command: 'bash scripts/serve.sh',
    cwd: fileURLToPath(new URL('../', import.meta.url)),
    url: 'http://127.0.0.1:21916',
    reuseExistingServer: false,
    timeout: 10000,
  },
});
