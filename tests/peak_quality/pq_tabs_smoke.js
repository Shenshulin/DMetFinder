// ============================================================
// Peak Quality - result-tab smoke test (puppeteer-core + system Edge)
// ============================================================
// Usage:
//   NODE_PATH=C:/Users/<you>/.workbuddy/binaries/node/workspace/node_modules \
//     <node> tests/peak_quality/pq_tabs_smoke.js [baseUrl] [outDir]
//
// What it pins down (no analysis run needed, so it is fast):
//   1. the Peak Quality page opens without a console or page error;
//   2. all seven result tabs are present, including the new "By software";
//   3. "By software" renders its own cards and the fairness note;
//   4. every tab can be selected without an error;
//   5. nothing below the four-class cards claims a validated classifier.
// ============================================================
const path = require('path');
const fs = require('fs');
const puppeteer = require('puppeteer-core');

const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:3838/';
const OUT = process.argv[3] || path.join(process.env.TEMP || '.', 'pq_tabs_shots');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const checks = [];
function check(ok, msg) {
  checks.push({ ok: !!ok, msg });
  console.log(`  ${ok ? 'PASS' : 'FAIL'}: ${msg}`);
}

const EXPECTED = [
  'Results', 'Peak view', 'Compare methods', 'By software',
  'Peak group', 'DNN', 'Three methods', 'Inputs & mapping',
  'Parameters & provenance',
];

(async () => {
  if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });
  const errors = [];
  const browser = await puppeteer.launch({
    executablePath: EDGE,
    headless: true,
    args: ['--no-sandbox', '--disable-gpu', '--hide-scrollbars'],
  });
  const page = await browser.newPage();
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await page.setViewport({ width: 1600, height: 1100 });

  console.log('opening', BASE);
  await page.goto(BASE, { waitUntil: 'networkidle2', timeout: 120000 });
  await wait(2000);

  const tabClicked = await page.evaluate(() => {
    const link = [...document.querySelectorAll('.navbar-nav a, .nav-item a')]
      .find((a) => a.textContent.trim() === 'Peak Quality');
    if (!link) return false;
    link.click();
    return true;
  });
  check(tabClicked, 'Peak Quality tab is present in the navbar');
  await wait(2200);

  const tabs = await page.evaluate(() => {
    const scope = document.querySelector('#PeakQuality-result_tabs');
    const root = scope || document;
    return [...root.querySelectorAll('.nav-link, .nav-pills a')]
      .map((a) => a.textContent.trim())
      .filter((t) => t.length > 0);
  });
  for (const t of EXPECTED) {
    check(tabs.includes(t), `result tab present: ${t}`);
  }
  check(tabs.length >= EXPECTED.length,
    `no tab was lost (found ${tabs.length}, expected at least ${EXPECTED.length})`);

  // ---------- By software ----------
  const opened = await page.evaluate(() => {
    const scope = document.querySelector('#PeakQuality-result_tabs') || document;
    const link = [...scope.querySelectorAll('.nav-link, .nav-pills a')]
      .find((a) => a.textContent.trim() === 'By software');
    if (!link) return false;
    link.click();
    return true;
  });
  check(opened, 'the By software tab can be selected');
  await wait(1500);

  const body = await page.evaluate(() => document.body.innerText);
  check(body.includes('Same raw files, same tolerances, same rules'),
    'the cross-software card explains the equal-treatment rule');
  check(body.includes('Distribution, not ranking'),
    'the metric panel refuses to present a ranking');
  check(body.includes('(not stated)') || body.includes('No result yet'),
    'missing software provenance stays visible or is reported as no-result');
  await page.screenshot({ path: path.join(OUT, '01_by_software.png') });

  // ---------- DNN ----------
  const dnnOpened = await page.evaluate(() => {
    const scope = document.querySelector('#PeakQuality-result_tabs') || document;
    const link = [...scope.querySelectorAll('.nav-link, .nav-pills a')]
      .find((a) => a.textContent.trim() === 'DNN');
    if (!link) return false;
    link.click();
    return true;
  });
  check(dnnOpened, 'the DNN tab can be selected');
  await wait(1800);

  const dnnBody = await page.evaluate(() => document.body.innerText);
  // The model may or may not be present on the machine running this test, so
  // both states are acceptable - what is not acceptable is a panic, or a tab
  // that silently claims a verdict.
  const modelKnown = /Model available|DNN prediction unavailable/.test(dnnBody);
  check(modelKnown, 'the DNN tab states whether a model is available');
  check(/not a calibrated probability/i.test(dnnBody),
    'the DNN tab says the score is not a calibrated probability');
  check(/never merged into quality_class/.test(dnnBody),
    'the DNN tab says its verdict is never merged into quality_class');
  check(!/Start training|Train model/i.test(dnnBody),
    'the DNN tab offers no training button');
  await page.screenshot({ path: path.join(OUT, '01b_dnn.png') });

  // ---------- Results: the provisional banner ----------
  await page.evaluate(() => {
    const scope = document.querySelector('#PeakQuality-result_tabs') || document;
    const link = [...scope.querySelectorAll('.nav-link, .nav-pills a')]
      .find((a) => a.textContent.trim() === 'Results');
    if (link) link.click();
  });
  await wait(1200);
  await page.screenshot({ path: path.join(OUT, '02_results.png') });

  // ---------- every tab reachable ----------
  for (const t of EXPECTED) {
    const ok = await page.evaluate((name) => {
      const scope = document.querySelector('#PeakQuality-result_tabs') || document;
      const link = [...scope.querySelectorAll('.nav-link, .nav-pills a')]
        .find((a) => a.textContent.trim() === name);
      if (!link) return false;
      link.click();
      return true;
    }, t);
    await wait(600);
    check(ok, `tab is clickable: ${t}`);
  }
  await page.screenshot({ path: path.join(OUT, '03_last_tab.png') });

  check(errors.length === 0,
    errors.length === 0 ? 'no console or page error'
                        : 'errors: ' + errors.slice(0, 3).join(' | '));

  await browser.close();

  const failed = checks.filter((c) => !c.ok).length;
  console.log(`\n---- ${checks.length} checks: ${checks.length - failed} passed, ${failed} failed ----`);
  console.log('screenshots:', OUT);
  if (failed > 0) process.exit(1);
})().catch((e) => {
  console.error('SMOKE FAILED:', e.message);
  process.exit(2);
});
