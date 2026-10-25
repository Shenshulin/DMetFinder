// ============================================================
// Peak Quality - DEMO run on real Thermo .raw data through the web UI
// ============================================================
// Not a test: it fills the Peak Quality page with a realistic parameter set,
// runs the assessment on real files, screenshots every step and downloads the
// exports so the run can be inspected afterwards.
//
//   NODE_PATH=C:/Users/<you>/.workbuddy/binaries/node/workspace/node_modules \
//     <node> tests/peak_quality/demo/demo_real_data.js [baseUrl] [outDir]
//
// Inputs (real data, repository external):
//   raw folder : G:/method_ms2/MSDIAL_TEST      (P173.raw, P176.raw, P181.raw, P528.raw)
//   peak table : peak_quality_demo_features.csv (derived by make_demo_peak_table.R:
//                real m/z + real apex RT picked from the MS1 scans of P173.raw)
// ============================================================
const path = require('path');
const fs = require('fs');
const puppeteer = require('puppeteer-core');

const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:7788/';
const OUT = process.argv[3] || path.join(process.env.TEMP || '.', 'pq_demo_real');
const RAW_DIR = 'G:/method_ms2/MSDIAL_TEST';
// argv[4] lets the same driver run an aligned (one row per feature) table
const PEAK_TABLE = process.argv[4] || path.join(RAW_DIR, 'peak_quality_demo_features.csv');
const ALIGNED = /aligned/.test(PEAK_TABLE);

const NS = 'PeakQuality';
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(...a);

// Shiny inputs are sometimes selectize-wrapped; try every common way to set one
async function setInput(page, id, value) {
  return page.evaluate((id, value) => {
    const el = document.getElementById(id);
    if (!el) return 'missing';
    if (el.selectize) { el.selectize.setValue(value, true); return 'selectize'; }
    if (window.jQuery) {
      const $el = window.jQuery(el);
      if ($el.data && $el.data('selectize')) {
        $el.data('selectize').setValue(value, true); return 'jquery-selectize';
      }
      $el.val(value).trigger('change'); return 'jquery';
    }
    el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return 'native';
  }, id, value);
}

const readVal = (page, id) => page.evaluate(
  (id) => { const el = document.getElementById(id); return el ? el.value : null; }, id);

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
  await page.setViewport({ width: 1600, height: 1150 });

  log('opening', BASE);
  await page.goto(BASE, { waitUntil: 'networkidle2', timeout: 120000 });
  await wait(2500);

  // ---- 1. switch to the Peak Quality tab ----
  await page.evaluate(() => {
    const link = [...document.querySelectorAll('.navbar-nav a, .nav-item a')]
      .find((a) => a.textContent.trim() === 'Peak Quality');
    if (link) link.click();
  });
  await wait(2000);
  await page.screenshot({ path: path.join(OUT, '01_tab.png') });

  // ---- 2. point the module at the real raw folder ----
  await setInput(page, `${NS}-workdir`, RAW_DIR);
  await wait(600);
  await page.click(`#${NS}-scan`);
  await wait(4000);
  const summary = await page.$eval(`#${NS}-file_summary`, (el) => el.innerText.trim());
  log('  raw files:', summary.replace(/\n/g, ' | '));

  // ---- 3. upload the peak table ----
  (await page.$(`#${NS}-peak_table`)).uploadFile(PEAK_TABLE);
  await wait(3000);
  const guess = {};
  for (const f of ['feature_id', 'mz', 'rt', 'sample_id']) {
    guess[f] = await readVal(page, `${NS}-map_${f}`);
  }
  log('  guessed mapping:', JSON.stringify(guess));

  // make sure the required fields are actually bound
  const want = ALIGNED
    ? { feature_id: 'Alignment ID', mz: 'Average Mz', rt: 'Average Rt(min)' }
    : { feature_id: 'feature_id', mz: 'mz', rt: 'rt', sample_id: 'sample_id' };
  for (const f of Object.keys(want)) {
    if (guess[f] !== want[f]) {
      log(`  -> forcing ${f} = ${want[f]} (was ${guess[f]})`);
      await setInput(page, `${NS}-map_${f}`, want[f]);
      await wait(400);
    }
  }
  await wait(1500);
  await page.screenshot({ path: path.join(OUT, '02_mapped.png') });

  // ---- 4. parameters ----
  await setInput(page, `${NS}-rt_unit`, 'min');        // RT in the table is minutes
  await setInput(page, `${NS}-mz_tol_unit`, 'ppm');
  await setInput(page, `${NS}-mz_tol_ppm`, '10');
  await setInput(page, `${NS}-xic_aggregate`, 'max');
  await setInput(page, `${NS}-rt_window`, '0.3');
  await setInput(page, `${NS}-min_points`, '5');
  await wait(1200);
  const params = {};
  for (const p of ['rt_unit', 'mz_tol_unit', 'mz_tol_ppm', 'xic_aggregate', 'rt_window', 'min_points']) {
    params[p] = await readVal(page, `${NS}-${p}`);
  }
  log('  parameters:', JSON.stringify(params));
  await page.screenshot({ path: path.join(OUT, '03_params.png'), fullPage: true });

  // ---- 5. run (reads two real 57 MB Thermo files, allow plenty of time) ----
  log('running the assessment on the real files ...');
  const t0 = Date.now();
  await page.click(`#${NS}-run`);
  let logTxt = '';
  let done = false;
  for (let i = 0; i < 60; i++) {          // up to ~10 min
    await wait(10000);
    logTxt = await page.evaluate((id) => {
      const el = document.getElementById(id);
      return el ? el.innerText.trim() : '';
    }, `${NS}-log`);
    if (/Done in|ABORTED|FATAL/.test(logTxt)) { done = true; break; }
    process.stdout.write('.');
  }
  process.stdout.write('\n');
  log(`  finished in ${((Date.now() - t0) / 1000).toFixed(0)} s; done=${done}`);
  log('  --- run log ---');
  log(logTxt.split('\n').map((l) => '    ' + l).join('\n'));

  await wait(2000);
  await page.screenshot({ path: path.join(OUT, '04_results.png'), fullPage: true });

  // ---- 6. results table ----
  const table = await page.evaluate((id) => {
    const host = document.getElementById(id);
    if (!host) return [];
    const rows = [...host.querySelectorAll('tbody tr')];
    return rows.slice(0, 20).map((r) =>
      [...r.querySelectorAll('td')].map((td) => td.innerText.trim()).join(' | '));
  }, `${NS}-results_table`);
  log(`  result rows (first ${table.length}):`);
  table.forEach((r) => log('    ' + r));

  const cards = await page.evaluate((id) => {
    const el = document.getElementById(id);
    return el ? el.innerText.replace(/\n/g, ' / ') : '';
  }, `${NS}-status_cards`);
  log('  summary cards:', cards);
  log('  sample scope input =', await readVal(page, `${NS}-sample_scope`));

  // ---- 6b. per-feature summary view ----
  await page.evaluate((id) => {
    const host = document.getElementById(id);
    if (!host) return;
    const r = [...host.querySelectorAll('input[type=radio]')]
      .find((x) => x.value === 'feature');
    if (r) { r.click(); r.dispatchEvent(new Event('change', { bubbles: true })); }
  }, `${NS}-table_view`);
  await wait(3000);
  const frows = await page.evaluate(() => {
    const host = document.getElementById('PeakQuality-feature_summary_table');
    if (!host) return [];
    return [...host.querySelectorAll('tbody tr')].slice(0, 12).map((r) =>
      [...r.querySelectorAll('td')].map((td) => td.innerText.trim()).join(' | '));
  });
  log(`  feature summary rows (${frows.length}):`);
  frows.forEach((r) => log('    ' + r));
  await page.screenshot({ path: path.join(OUT, '05b_feature_summary.png'), fullPage: true });

  await page.evaluate((id) => {
    const host = document.getElementById(id);
    if (!host) return;
    const r = [...host.querySelectorAll('input[type=radio]')]
      .find((x) => x.value === 'sample');
    if (r) { r.click(); r.dispatchEvent(new Event('change', { bubbles: true })); }
  }, `${NS}-table_view`);
  await wait(1500);

  // ---- 7. peak view ----
  await page.evaluate(() => {
    const link = [...document.querySelectorAll('.nav-pills a, .nav-tabs a')]
      .find((a) => a.textContent.trim() === 'Peak view');
    if (link) link.click();
  });
  await wait(4000);
  await page.screenshot({ path: path.join(OUT, '05_peak_view.png'), fullPage: true });

  // second feature as well, to show the result is not a one-off
  const opts = await page.evaluate((id) => {
    const el = document.getElementById(id);
    return el ? [...el.options].map((o) => o.value) : [];
  }, `${NS}-peak_key`);
  if (opts.length > 1) {
    await setInput(page, `${NS}-peak_key`, opts[Math.min(3, opts.length - 1)]);
    await wait(4000);
    await page.screenshot({ path: path.join(OUT, '06_peak_view_2.png'), fullPage: true });
  }
  await page.click(`#${NS}-show_fit`);
  await wait(4000);
  await page.screenshot({ path: path.join(OUT, '07_fit.png'), fullPage: true });

  // ---- 8. downloads ----
  const dlDir = path.join(OUT, 'downloads');
  if (!fs.existsSync(dlDir)) fs.mkdirSync(dlDir, { recursive: true });
  const client = await page.createCDPSession();
  await client.send('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: dlDir });
  await page.evaluate(() => {
    const link = [...document.querySelectorAll('.nav-pills a, .nav-tabs a')]
      .find((a) => a.textContent.trim() === 'Results');
    if (link) link.click();
  });
  await wait(1500);
  for (const [btn, pause] of [['dl_csv', 4000], ['dl_xlsx', 8000], ['dl_report', 25000]]) {
    await page.evaluate((b) => document.getElementById(`PeakQuality-${b}`).click(), btn);
    await wait(pause);
  }
  log('  downloaded:', fs.readdirSync(dlDir).join(', '));

  // ---- 9. parameters & provenance tab ----
  await page.evaluate(() => {
    const link = [...document.querySelectorAll('.nav-pills a, .nav-tabs a')]
      .find((a) => /Parameters/.test(a.textContent));
    if (link) link.click();
  });
  await wait(2500);
  await page.screenshot({ path: path.join(OUT, '08_provenance.png'), fullPage: true });

  log('  console/page errors:', errors.length ? errors.slice(0, 3).join(' | ') : 0);
  await browser.close();
  log('screenshots + exports:', OUT);
})().catch((e) => { console.error('demo crashed:', e); process.exit(2); });
