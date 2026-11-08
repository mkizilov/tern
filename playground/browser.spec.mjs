import { test, expect } from '@playwright/test';
import { readFileSync, readdirSync } from 'node:fs';

async function source(page, text) {
  await page.getByRole('textbox', { name: 'Tern source' }).fill(text);
}
async function run(page, expected = 'Completed') {
  await page.getByRole('button', { name: '▶ Run', exact: true }).click();
  await expect(page.getByRole('status')).toHaveText(expected, { timeout: 15000 });
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('#examples option')).toHaveCount(16);
});

test('all examples compile in the real browser and match exact golden output', async ({ page }) => {
  const errors = [];
  const requests = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => requests.push({ url: request.url(), method: request.method() }));
  const files = readdirSync('examples').filter(file => file.endsWith('.tern')).sort();
  for (const file of files) {
    await page.selectOption('#examples', file);
    await run(page);
    expect(await page.locator('#output').textContent(), file).toBe(readFileSync(`examples/${file.replace('.tern', '.out')}`, 'utf8'));
  }
  await page.getByRole('tab', { name: 'Inferred types' }).click();
  await expect(page.locator('#types')).toContainText('val map');
  await page.getByRole('tab', { name: 'ANF IR' }).click();
  await expect(page.locator('#ir')).not.toHaveText('');
  await page.getByRole('tab', { name: 'Generated WAT' }).click();
  await expect(page.locator('#wat')).toContainText('(module');
  expect(errors).toEqual([]);
  expect(requests.length).toBeGreaterThan(0);
  for (const request of requests) {
    expect(new URL(request.url).origin).toBe('http://127.0.0.1:21916');
    expect(request.method).toBe('GET');
  }
});

test('type errors highlight the exact Unicode-aware span and edits clear stale results', async ({ page }) => {
  await source(page, 'let feather = "🪶é";;\nlet bad = 1 + true;;');
  await run(page, 'Compilation failed');
  await expect(page.locator('#diagnostics')).toContainText('expected int, but got bool');
  await expect(page.locator('.cm-lintRange-error')).toHaveText('true');
  await source(page, 'let () = print_int 42;;');
  await expect(page.locator('.cm-lintRange-error')).toHaveCount(0);
  await run(page);
  expect(await page.locator('#output').textContent()).toBe('42');
});

test('warnings are rendered and highlighted without blocking execution', async ({ page }) => {
  await source(page, 'let f x = match x with true -> 42;; let () = print_int (f true);;');
  await run(page);
  await expect(page.locator('#diagnostics')).toContainText('non-exhaustive');
  await expect(page.locator('.cm-lintRange-warning')).toHaveCount(1);
  expect(await page.locator('#output').textContent()).toBe('42');
});

test('runtime traps preserve preceding stdout and do not invent source locations', async ({ page }) => {
  await source(page, 'let () = print_string "before"; print_int (1 / 0);;');
  await run(page, 'Stopped with error');
  expect(await page.locator('#output').textContent()).toBe('before');
  await expect(page.locator('#diagnostics')).toContainText('RuntimeError');
  await expect(page.locator('.cm-lintRange-error')).toHaveCount(0);
});

test('an infinite Wasm program is cancellable and the next run still works', async ({ page }) => {
  await source(page, 'let rec loop n = loop n;; let () = print_string "started"; print_int (loop 0);;');
  await page.getByRole('button', { name: '▶ Run', exact: true }).click();
  await expect(page.locator('#output')).toHaveText('started');
  await page.getByRole('button', { name: '■ Stop', exact: true }).click();
  await expect(page.getByRole('status')).toHaveText('Stopped');
  await source(page, 'let () = print_int 7;;');
  await run(page);
  expect(await page.locator('#output').textContent()).toBe('7');
});

test('timeouts and output limits terminate workers and preserve UI responsiveness', async ({ page }) => {
  await source(page, 'let rec loop n = loop n;; let () = print_int (loop 0);;');
  await run(page, 'Stopped with error');
  await expect(page.locator('#diagnostics')).toContainText('5 second limit');
  await source(page, `let () = print_string "${'a'.repeat(65537)}";;`);
  await run(page, 'Stopped with error');
  await expect(page.locator('#diagnostics')).toContainText('64 KiB');
  await source(page, `(*${'🪶'.repeat(65536)}*)`);
  await run(page, 'Stopped with error');
  await expect(page.locator('#diagnostics')).toContainText('256 KiB');
});

test('output is text, tab navigation works, and the mobile layout has no page overflow', async ({ page }) => {
  await source(page, 'let () = print_string "<img src=x onerror=alert(1)>";;');
  await run(page);
  expect(await page.locator('#output').textContent()).toBe('<img src=x onerror=alert(1)>');
  await expect(page.locator('#output img')).toHaveCount(0);
  await page.getByRole('tab', { name: 'Inferred types' }).focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'ANF IR' })).toHaveAttribute('aria-selected', 'true');
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('late example loading never overwrites an edited program and the run shortcut works', async ({ page }) => {
  let release;
  await page.route('**/examples.json', route => new Promise(resolve => {
    release = async () => { await route.continue(); resolve(); };
  }));
  await page.goto('/');
  await source(page, 'let () = print_int 9;;');
  await expect.poll(() => typeof release).toBe('function');
  await release();
  await expect(page.locator('#examples option')).toHaveCount(16);
  await page.getByRole('textbox', { name: 'Tern source' }).press('ControlOrMeta+Enter');
  await expect(page.getByRole('status')).toHaveText('Completed');
  expect(await page.locator('#output').textContent()).toBe('9');
});
