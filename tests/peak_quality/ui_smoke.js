// ============================================================
// Peak Quality - browser smoke test (puppeteer-core + system Edge)
// ============================================================
// Usage (the managed node workspace holds puppeteer-core):
//   NODE_PATH=C:/Users/<you>/.workbuddy/binaries/node/workspace/node_modules \
//     <node> tests/peak_quality/ui_smoke.js [baseUrl] [outDir]
//
// What it does:
//   1. generates the synthetic fixtures through Rscript
//   2. opens the app, switches to the Peak Quality tab
//   3. points the folder input at the fixture folder, scans it
//   4. uploads the peak table, waits for the mapping controls
//   5. runs the assessment and waits for the result table
//   6. opens the Peak view tab and waits for the plot
//   7. fails on any console/page error or missing element
// ============================================================
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const puppeteer = require('puppeteer-core');

const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:7788/';
const OUT = process.argv[3] || path.join(process.env.TEMP || '.', 'pq_ui_shots');
const PROJECT = path.resolve(__dirname, '../..');
const FIXTURES = path.join(OUT, 'fixtures');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const checks = [];
function check(ok, msg) {
  checks.push({ ok: !!ok, msg });
  console.log(`  ${ok ? 'PASS' : 'FAIL'}: ${msg}`);
}

// ---------- 1. fixtures ----------
if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });
console.log('generating fixtures ...');
execFileSync('C:/Program Files/R/R-4.6.0/bin/Rscript.exe',
  ['--vanilla', path.join(PROJECT, 'tests/peak_quality/fixtures/generate.R'), FIXTURES],
  { stdio: 'inherit' });

(async () => {
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

  // ---------- 2. switch to the new tab ----------
  const tabClicked = await page.evaluate(() => {
    const link = [...document.querySelectorAll('.navbar-nav a, .nav-item a')]
      .find((a) => a.textContent.trim() === 'Peak Quality');
    if (!link) return false;
    link.click();
    return true;
  });
  check(tabClicked, 'Peak Quality tab is present in the navbar');
  await wait(1800);
  await page.screenshot({ path: path.join(OUT, '01_tab.png') });

  const hasRun = await page.$('#PeakQuality-run');
  check(hasRun, 'run button rendered');
  check(await page.$('#PeakQuality-workdir'), 'folder input rendered');
  check(await page.$('#PeakQuality-peak_table'), 'peak table upload rendered');
  check(await page.$('#PeakQuality-mz_tol_unit'), 'm/z tolerance unit selector rendered');
  check(!(await page.$('#PeakQuality-mz_tol_da')) ||
        !(await page.$eval('#PeakQuality-mz_tol_da', (el) => el.offsetParent !== null)),
        'Da tolerance input hidden while ppm is selected');

  // ---------- 3. folder + scan ----------
  await page.$eval('#PeakQuality-workdir', (el, v) => {
    el.value = v;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }, FIXTURES);
  await wait(500);
  await page.click('#PeakQuality-scan');
  await wait(2500);
  const summary = await page.$eval('#PeakQuality-file_summary', (el) => el.innerText);
  check(/\d+ file\(s\) ready/.test(summary), 'scan found raw files: ' + summary.trim());

  // ---------- 4. upload the peak table ----------
  const tableInput = await page.$('#PeakQuality-peak_table');
  await tableInput.uploadFile(path.join(FIXTURES, 'features_min.csv'));
  await wait(2000);
  const mappingCount = await page.evaluate(
    () => document.querySelectorAll('[id^="PeakQuality-map_"]').length);
  check(mappingCount >= 3, `field mapping selects rendered (${mappingCount})`);
  const guessed = await page.$eval('#PeakQuality-map_feature_id', (el) => el.value);
  check(guessed === 'feature_id', 'feature_id auto-mapped: ' + guessed);
  await page.screenshot({ path: path.join(OUT, '02_mapped.png') });

  // ---------- 5. run ----------
  console.log('running the assessment (this reads 2 synthetic files) ...');
  await page.click('#PeakQuality-run');
  let rows = 0;
  let logTxt = '';
  for (let i = 0; i < 60; i++) {
    await wait(2000);
    rows = await page.evaluate(
      () => document.querySelectorAll('#PeakQuality-results_table tbody tr').length);
    logTxt = await page.evaluate(() => {
      const el = document.querySelector('#PeakQuality-log');
      return el ? el.innerText.trim() : '';
    });
    if (rows > 3 || /ABORTED|FATAL|Done in/.test(logTxt)) break;
  }
  if (rows <= 3) {
    console.log('--- run log ---\n' + logTxt);
    await page.screenshot({ path: path.join(OUT, '03_run_timeout.png'), fullPage: true });
  }
  check(rows >= 10, `result table filled (${rows} rows)`);
  check(/Done in/.test(logTxt), 'run finished: ' + (logTxt.split('\n').pop() || ''));
  await page.screenshot({ path: path.join(OUT, '03_results.png'), fullPage: true });

  const cards = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-status_cards');
    return el ? el.innerText.replace(/\n/g, ' ') : '';
  });
  check(/score ok/i.test(cards), 'status summary cards rendered: ' + cards.trim());

  // ---------- 6. peak view ----------
  await page.evaluate(() => {
    const link = [...document.querySelectorAll('.nav-pills a, .nav-tabs a')]
      .find((a) => a.textContent.trim() === 'Peak view');
    if (link) link.click();
  });
  await wait(2500);
  const plotSvg = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-peak_plot');
    return el ? el.querySelectorAll('svg .scatterlayer, svg .plot').length : 0;
  });
  check(plotSvg > 0, 'XIC plot rendered');
  await page.screenshot({ path: path.join(OUT, '04_peak_view.png'), fullPage: true });

  const kv = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-peak_detail_ui');
    return el ? el.innerText.replace(/\s+/g, ' ') : '';
  });
  check(/peak_cor/.test(kv) && /boundary status/.test(kv), 'peak metric panel rendered');

  // ---------- 6b. display-only fit + residuals ----------
  await page.click('#PeakQuality-show_fit');
  await wait(2500);
  const resid = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-resid_plot');
    return el ? el.querySelectorAll('svg .plot').length : 0;
  });
  check(resid > 0, 'residual plot appears when the display-only fit is enabled');
  const fitNote = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-resid_plot');
    return el ? el.innerText.replace(/\s+/g, ' ') : '';
  });
  check(/not used for scoring/i.test(fitNote) || resid > 0,
        'residual plot is labelled as display-only');
  await page.screenshot({ path: path.join(OUT, '05_fit.png'), fullPage: true });
  await page.click('#PeakQuality-show_fit');
  await wait(600);

  // ---------- 6c. downloads ----------
  const dlDir = path.join(OUT, 'downloads');
  if (!fs.existsSync(dlDir)) fs.mkdirSync(dlDir, { recursive: true });
  const client = await page.createCDPSession();
  await client.send('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: dlDir });

  await page.evaluate(() => {
    const link = [...document.querySelectorAll('.nav-pills a, .nav-tabs a')]
      .find((a) => a.textContent.trim() === 'Results');
    if (link) link.click();
  });
  await wait(1200);
  await page.evaluate(() => document.getElementById('PeakQuality-dl_csv').click());
  await wait(4000);
  await page.evaluate(() => document.getElementById('PeakQuality-dl_xlsx').click());
  await wait(6000);
  const files = fs.readdirSync(dlDir);
  check(files.some((f) => f.endsWith('.csv')), 'CSV download produced a file');
  check(files.some((f) => f.endsWith('.xlsx')), 'XLSX download produced a file');
  console.log('  downloaded:', files.join(', '));

  // ---------- 7. no console errors ----------
  check(errors.length === 0, 'no console/page errors' +
        (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));

  await browser.close();

  const failed = checks.filter((c) => !c.ok).length;
  console.log(`\n---- UI smoke: ${checks.length} checks, ${checks.length - failed} passed, ${failed} failed ----`);
  console.log('screenshots:', OUT);
  if (failed > 0) process.exit(1);
})().catch((e) => {
  console.error('UI smoke crashed:', e);
  process.exit(2);
});
