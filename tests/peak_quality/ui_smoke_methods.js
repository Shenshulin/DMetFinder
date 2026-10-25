// ============================================================
// Stage-2/3 browser test: method selection, Compare methods, Peak group
// ============================================================
// Usage (managed node workspace holds puppeteer-core):
//   NODE_PATH=C:/Users/<you>/.workbuddy/binaries/node/workspace/node_modules \
//     <node> tests/peak_quality/ui_smoke_methods.js [baseUrl] [outDir]
//
// Requires the app to be started with DMETFINDER_CPC_LIB pointing at a
// library that holds cpc; otherwise the CPC checkbox is disabled and the
// test reports that instead of failing.
// ============================================================
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const puppeteer = require('puppeteer-core');

const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = process.argv[2] || 'http://127.0.0.1:7788/';
const OUT = process.argv[3] || path.join(process.env.TEMP || '.', 'pq_ui_methods');
const PROJECT = path.resolve(__dirname, '../..');
const FIXTURES = path.join(OUT, 'fixtures');

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const checks = [];
function check(ok, msg) {
  checks.push({ ok: !!ok, msg });
  console.log(`  ${ok ? 'PASS' : 'FAIL'}: ${msg}`);
}

if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });
if (!fs.existsSync(path.join(FIXTURES, 'features_min.csv'))) {
  console.log('generating fixtures ...');
  execFileSync('C:/Program Files/R/R-4.6.0/bin/Rscript.exe',
    ['--vanilla', path.join(PROJECT, 'tests/peak_quality/fixtures/generate.R'), FIXTURES],
    { stdio: 'inherit' });
}

const clickTab = (page, label) => page.evaluate((l) => {
  const link = [...document.querySelectorAll('.nav-pills a, .nav-tabs a, .navbar-nav a')]
    .find((a) => a.textContent.trim() === l);
  if (!link) return false;
  link.click();
  return true;
}, label);

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
  await page.setViewport({ width: 1700, height: 1100 });

  await page.goto(BASE, { waitUntil: 'networkidle2', timeout: 120000 });
  await wait(1500);
  check(await clickTab(page, 'Peak Quality'), 'Peak Quality tab opens');
  await wait(1800);

  // ---------- method section ----------
  check(!!(await page.$('#PeakQuality-method_choices_ui')), 'method section rendered');
  check(!!(await page.$('#PeakQuality-method_cpc')), 'CPC checkbox rendered');
  const cpcDisabled = await page.$eval('#PeakQuality-method_cpc', (el) => el.disabled);
  const dnnBox = !!(await page.$('#PeakQuality-method_dnn'));
  check(dnnBox, 'DNN peak-group checkbox rendered');
  const statusTxt = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-method_status_ui');
    return el ? el.innerText.replace(/\s+/g, ' ') : '';
  });
  check(/kumler/i.test(statusTxt), 'method status strip lists Kumler: ' + statusTxt.trim());
  console.log('  CPC checkbox disabled:', cpcDisabled);
  await page.screenshot({ path: path.join(OUT, '01_methods.png'), fullPage: true });

  // ---------- inputs ----------
  await page.$eval('#PeakQuality-workdir', (el, v) => {
    el.value = v;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }, FIXTURES);
  await wait(400);
  await page.click('#PeakQuality-scan');
  await wait(2200);
  const tableInput = await page.$('#PeakQuality-peak_table');
  await tableInput.uploadFile(path.join(FIXTURES, 'features_min.csv'));
  await wait(1800);

  if (!cpcDisabled) {
    await page.click('#PeakQuality-method_cpc');
    await wait(300);
    check(await page.$eval('#PeakQuality-method_cpc', (el) => el.checked),
      'CPC can be enabled');
  }
  await page.click('#PeakQuality-method_dnn');
  await wait(300);

  // ---------- run ----------
  console.log('running with CPC enabled (reads 2 synthetic raw files) ...');
  await page.click('#PeakQuality-run');
  let logTxt = '';
  let rows = 0;
  for (let i = 0; i < 90; i++) {
    await wait(2000);
    rows = await page.evaluate(
      () => document.querySelectorAll('#PeakQuality-results_table tbody tr').length);
    logTxt = await page.evaluate(() => {
      const el = document.querySelector('#PeakQuality-log');
      return el ? el.innerText.trim() : '';
    });
    if ((rows > 3 && /Done in/.test(logTxt)) || /ABORTED|FATAL/.test(logTxt)) break;
  }
  if (!/Done in/.test(logTxt)) {
    console.log('--- run log ---\n' + logTxt);
    await page.screenshot({ path: path.join(OUT, '02_run_failed.png'), fullPage: true });
  }
  check(/Done in/.test(logTxt), 'run finished');
  // A finished run is not a rendered run. When the DNN succeeded it used to
  // replace results() with a bare data.frame, so det$rows became NULL and both
  // the cards and the table died with "missing value where TRUE/FALSE needed"
  // and "incorrect number of dimensions" - while "Done in" still matched.
  check(rows > 0, `results table rendered rows (${rows})`);
  const outErrs = await page.evaluate(
    () => [...document.querySelectorAll('.shiny-output-error')]
      .map((e) => e.innerText.replace(/\s+/g, ' ').trim()));
  check(outErrs.length === 0,
    'no Shiny output error on the Results tab' +
    (outErrs.length ? ': ' + outErrs.join(' | ') : ''));
  const dnnLine = (logTxt.match(/DNN (scored|produced no score|was ticked)[^\n]*/) || [''])[0];
  check(dnnLine !== '', 'the DNN branch was exercised: ' + dnnLine);
  const cpcRan = /CPC finished|CPC: ok=/.test(logTxt);
  if (!cpcDisabled) check(cpcRan, 'CPC actually ran on the same peaks');
  await page.screenshot({ path: path.join(OUT, '02_results.png'), fullPage: true });

  // ---------- compare methods ----------
  check(await clickTab(page, 'Compare methods'), 'Compare methods tab exists');
  await wait(3000);
  const cmpCards = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-compare_cards');
    return el ? el.innerText.replace(/\s+/g, ' ') : '';
  });
  check(/both methods scored/i.test(cmpCards), 'agreement cards rendered: ' + cmpCards.trim());
  check(/median \|d apex RT\|/i.test(cmpCards), 'apex difference card present');

  const cmpRows = await page.evaluate(
    () => document.querySelectorAll('#PeakQuality-compare_table tbody tr').length);
  check(cmpRows > 0, `comparison table has rows (${cmpRows})`);
  const metricRows = await page.evaluate(
    () => document.querySelectorAll('#PeakQuality-metrics_table tbody tr').length);
  check(metricRows > 0, `native metric table has rows (${metricRows})`);
  const unifiedRows = await page.evaluate(
    () => document.querySelectorAll('#PeakQuality-unified_preview tbody tr').length);
  check(unifiedRows > 0, `unified preview has rows (${unifiedRows})`);

  const cmpHeader = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-compare_table');
    if (!el) return '';
    return [...el.querySelectorAll('table thead th')].map((th) => th.innerText.trim()).join(' ');
  });
  check(/kumler_/.test(cmpHeader) && /cpc_/.test(cmpHeader),
    'comparison table exposes kumler_* and cpc_* columns');
  check(!/total|composite|combined/i.test(cmpHeader),
    'comparison table has no combined-score column');
  await page.screenshot({ path: path.join(OUT, '03_compare.png'), fullPage: true });

  // ---------- peak group ----------
  check(await clickTab(page, 'Peak group'), 'Peak group tab exists');
  await wait(3500);
  const intro = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-group_intro_ui');
    return el ? el.innerText.replace(/\s+/g, ' ') : '';
  });
  check(/no trained weights/i.test(intro), 'the DNN limitation is stated in the UI');

  const imgSvg = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-group_image');
    if (!el) return 0;
    return el.querySelectorAll('svg image, svg .heatmaplayer, svg .plot').length;
  });
  check(imgSvg > 0, 'peak-group image rendered');
  const trSvg = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-group_traces');
    return el ? el.querySelectorAll('svg .plot').length : 0;
  });
  check(trSvg > 0, 'member traces rendered');
  const oneTbl = await page.evaluate(() => {
    const el = document.querySelector('#PeakQuality-group_one_table');
    return el ? el.innerText.replace(/\s+/g, ' ') : '';
  });
  check(/admissibility/i.test(oneTbl), 'group diagnostics table rendered');

  await page.click('#PeakQuality-build_groups');
  let diagRows = 0;
  for (let i = 0; i < 30; i++) {
    await wait(1500);
    diagRows = await page.evaluate(
      () => document.querySelectorAll('#PeakQuality-group_diag_table tbody tr').length);
    if (diagRows > 1) break;
  }
  check(diagRows > 1, `all-feature diagnostics table filled (${diagRows})`);
  await page.screenshot({ path: path.join(OUT, '04_peak_group.png'), fullPage: true });

  // ---------- downloads ----------
  const dlDir = path.join(OUT, 'downloads');
  if (!fs.existsSync(dlDir)) fs.mkdirSync(dlDir, { recursive: true });
  const client = await page.createCDPSession();
  await client.send('Page.setDownloadBehavior', { behavior: 'allow', downloadPath: dlDir });

  await clickTab(page, 'Compare methods');
  await wait(1200);
  await page.evaluate(() => document.getElementById('PeakQuality-dl_compare').click());
  await wait(4000);
  const files = fs.readdirSync(dlDir);
  check(files.some((f) => f.startsWith('peak_quality_compare') && f.endsWith('.csv')),
    'comparison CSV downloaded');

  await clickTab(page, 'Results');
  await wait(1000);
  await page.evaluate(() => document.getElementById('PeakQuality-dl_xlsx').click());
  await wait(8000);
  const xlsx = fs.readdirSync(dlDir).find((f) => f.endsWith('.xlsx'));
  check(!!xlsx, 'XLSX downloaded');
  if (xlsx) {
    const sheetOut = execFileSync('C:/Program Files/R/R-4.6.0/bin/Rscript.exe',
      ['--vanilla', '-e',
       `cat(openxlsx::getSheetNames("${path.join(dlDir, xlsx).replace(/\\/g, '/')}"), sep=",")`],
      { encoding: 'utf8' });
    console.log('  sheets:', sheetOut.trim());
    for (const s of ['UnifiedResults', 'MethodComparison', 'CpcPeaks', 'ColumnDictionary', 'Methods']) {
      check(sheetOut.includes(s), `XLSX has the ${s} sheet`);
    }
  }

  check(errors.length === 0, 'no console/page errors' +
    (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));

  await browser.close();
  const failed = checks.filter((c) => !c.ok).length;
  console.log(`\n---- UI methods smoke: ${checks.length} checks, ${checks.length - failed} passed, ${failed} failed ----`);
  console.log('screenshots:', OUT);
  if (failed > 0) process.exit(1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
