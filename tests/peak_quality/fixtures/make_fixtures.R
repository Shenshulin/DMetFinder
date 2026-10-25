# ============================================================
# Synthetic test fixtures for the Peak Quality module
# ============================================================
# These files are SYNTHETIC. Passing tests here proves the extraction /
# boundary / scoring logic, NOT that a real instrument file parses correctly
# - that is covered separately by test_06_real_raw.R.
#
# Content of each generated file (deterministic, no RNG):
#   MS1 scans every 0.005 min from 5.00 to 8.00 min  (601 scans)
#   one MS2 scan after every 10th MS1 scan           (tests MS1 selection)
#   ions (retention time in minutes, sigma in minutes):
#     F_CLEAN     301.1234  gaussian apex 6.00 sigma 0.060 height 1.0e5
#     F_NOISY     401.2000  gaussian apex 6.50 sigma 0.050 height 8.0e4 + 6% ripple
#     F_TWO       451.3000  two peaks apex 6.05 (9e4) and 6.25 (7e4), sigma 0.035
#     F_SHOULDER  501.4000  apex 6.20 (1.0e5) + shoulder apex 6.40 (3.5e4)
#     F_MULTI     551.5000  apex 6.30 height 6e4  + 551.5028 height 5e4
#     F_LATE      601.6000  apex 7.50 height 9e4   (outside a 6.00 +- 0.30 window)
#     F_SHIFT     651.7000  apex 6.25 height 9e4   (inside window, apex 0.25 from input)
#     F_EDGE      701.8000  apex 5.82 height 7e4   (left flank cut by the window)
#     F_NARROW    751.9000  apex 6.0025 sigma 0.002 (only 4 scans in the peak)
#     F_NOSIGNAL  999.9000  not present at all
#     background  120.0500 (500) and 250.0700 (300) in every scan
# ============================================================

pq_fixture_scans <- function() seq(5.00, 8.00, by = 0.005)

pq_fixture_truth <- function() {
  data.frame(
    feature_id = c("F_CLEAN", "F_NOISY", "F_TWO", "F_SHOULDER", "F_MULTI",
                   "F_LATE", "F_SHIFT", "F_EDGE", "F_NARROW", "F_NOSIGNAL"),
    mz = c(301.1234, 401.2000, 451.3000, 501.4000, 551.5000,
           601.6000, 651.7000, 701.8000, 751.9000, 999.9000),
    rt = c(6.00, 6.50, 6.15, 6.20, 6.30,
           6.00, 6.00, 6.00, 6.00, 6.00),
    expected = c("clean single peak", "noisy single peak", "two local maxima",
                 "asymmetric / shoulder", "two ions inside the m/z window",
                 "apex far outside the RT window", "apex just outside tolerance",
                 "left flank clipped by the window", "only 3 scans in the peak",
                 "no signal at all"),
    stringsAsFactors = FALSE
  )
}

# Intensity profile of one ion at one RT
pq_fixture_gauss <- function(rt, apex, sigma, height) {
  height * exp(-((rt - apex)^2) / (2 * sigma^2))
}

pq_fixture_spectrum <- function(rt, file_tag = 1) {
  mult <- if (identical(file_tag, 1)) 1 else 0.6

  clean    <- pq_fixture_gauss(rt, 6.00, 0.060, 1.0e5) * mult
  noisy    <- pq_fixture_gauss(rt, 6.50, 0.050, 8.0e4) * mult
  two      <- (pq_fixture_gauss(rt, 6.05, 0.035, 9.0e4) +
                 pq_fixture_gauss(rt, 6.25, 0.035, 7.0e4)) * mult
  shoulder <- (pq_fixture_gauss(rt, 6.20, 0.050, 1.0e5) +
                 pq_fixture_gauss(rt, 6.40, 0.030, 3.5e4)) * mult
  multi    <- pq_fixture_gauss(rt, 6.30, 0.050, 6.0e4) * mult
  multi2   <- pq_fixture_gauss(rt, 6.30, 0.050, 5.0e4) * mult
  late     <- pq_fixture_gauss(rt, 7.50, 0.050, 9.0e4) * mult
  shift    <- pq_fixture_gauss(rt, 6.25, 0.050, 9.0e4) * mult
  edge     <- pq_fixture_gauss(rt, 5.82, 0.060, 7.0e4) * mult
  narrow   <- pq_fixture_gauss(rt, 6.0025, 0.002, 5.0e4) * mult

  # deterministic low-frequency ripple for F_NOISY (6% of its height)
  ripple <- 0.06 * 8.0e4 * mult *
    (0.6 * sin(rt * 131.2) + 0.4 * sin(rt * 57.7 + 1.3))

  mz <- c(120.0500, 250.0700, 301.1234, 401.2000, 451.3000, 501.4000,
          551.5000, 551.5028, 601.6000, 651.7000, 701.8000, 751.9000)
  int <- c(500, 300, clean, max(0, noisy + ripple), two, shoulder,
           multi, multi2, late, shift, edge, narrow)

  keep <- int > 0
  list(mz = mz[keep], intensity = round(int[keep], 2))
}

# ------------------------------------------------------------
# mzML writer
# ------------------------------------------------------------
pq_b64_le <- function(x) base64enc::base64encode(writeBin(as.double(x), raw(), size = 8, endian = "little"))

pq_bda <- function(vals, acc, nm) {
  b <- pq_b64_le(vals)
  sprintf(paste0('<binaryDataArray encodedLength="%d">',
                 '<cvParam cvRef="MS" accession="MS:1000523" name="64-bit float" value=""/>',
                 '<cvParam cvRef="MS" accession="MS:1000576" name="no compression" value=""/>',
                 '<cvParam cvRef="MS" accession="%s" name="%s" value=""/>',
                 '<binary>%s</binary></binaryDataArray>'),
          nchar(b), acc, nm, b)
}

pq_mzml_spectrum <- function(idx, level, rt_sec, mzv, inv, prec = NULL) {
  n <- length(mzv)
  lvl_acc <- if (level == 1) "MS:1000579" else "MS:1000580"
  lvl_nm  <- if (level == 1) "MS1 spectrum" else "MSn spectrum"
  prec_blk <- if (level >= 2) {
    sprintf(paste0('<precursorList count="1"><precursor><selectedIonList count="1">',
                   '<selectedIon><cvParam cvRef="MS" accession="MS:1000744" ',
                   'name="selected ion m/z" value="%s"/></selectedIon>',
                   '</selectedIonList></precursor></precursorList>'), prec)
  } else ""
  sprintf(paste0('<spectrum index="%d" id="scan=%d" defaultArrayLength="%d">',
                 '<cvParam cvRef="MS" accession="%s" name="%s" value=""/>',
                 '<cvParam cvRef="MS" accession="MS:1000511" name="ms level" value="%d"/>',
                 '<cvParam cvRef="MS" accession="MS:1000127" name="centroid spectrum" value=""/>',
                 '<cvParam cvRef="MS" accession="MS:1000129" name="negative ion mode" value=""/>',
                 '<scanList count="1"><scan>',
                 '<cvParam cvRef="MS" accession="MS:1000016" name="scan start time" value="%.3f" ',
                 'unitCvRef="UO" unitAccession="UO:0000010" unitName="second"/>',
                 '</scan></scanList>%s',
                 '<binaryDataArrayList count="2">%s%s</binaryDataArrayList>',
                 '</spectrum>'),
          idx, idx, n, lvl_acc, lvl_nm, level, rt_sec, prec_blk,
          pq_bda(mzv, "MS:1000514", "m/z array"),
          pq_bda(inv, "MS:1000515", "intensity array"))
}

pq_write_mzml <- function(path, file_tag = 1) {
  rts <- pq_fixture_scans()
  specs <- character(0)
  idx <- 0L
  for (i in seq_along(rts)) {
    sp <- pq_fixture_spectrum(rts[i], file_tag)
    idx <- idx + 1L
    specs <- c(specs, pq_mzml_spectrum(idx, 1, rts[i] * 60, sp$mz, sp$intensity))
    if (i %% 10 == 0) {
      idx <- idx + 1L
      specs <- c(specs, pq_mzml_spectrum(idx, 2, rts[i] * 60,
                                         c(301.1234, 250.07), c(1200, 300),
                                         prec = "301.1234"))
    }
  }

  header <- c(
    '<?xml version="1.0" encoding="utf-8"?>',
    '<mzML version="1.1.0" xmlns="http://psi.hupo.org/schema/mzml" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://psi.hupo.org/schema/mzml http://psi.hupo.org/schema/mzml_1.1.0/mzML1.1.0.xsd">',
    '<cvList count="1"><cv id="MS" fullName="PSI MS Ontology" version="1.3.1" URI="http://psidev.info/psi/ms/ms-ontology"/></cvList>',
    '<fileDescription><fileContent><cvParam cvRef="MS" accession="MS:1000579" name="MS1 spectrum" value=""/></fileContent></fileDescription>',
    '<referenceableParamGroupList count="0"/>',
    '<sampleList count="0"/>',
    '<softwareList count="1"><software id="pwiz" version="1.0"/></softwareList>',
    '<instrumentConfigurationList count="1"><instrumentConfiguration id="IC1"><cvParam cvRef="MS" accession="MS:1000031" name="instrument model" value=""/></instrumentConfiguration></instrumentConfigurationList>',
    '<dataProcessingList count="1"><dataProcessing id="dp" softwareRef="pwiz"><processingMethod order="1" softwareRef="pwiz"><cvParam cvRef="MS" accession="MS:1000551" name="Conversion to mzML" value=""/></processingMethod></dataProcessing></dataProcessingList>',
    sprintf('<run id="run1" defaultInstrumentConfigurationRef="IC1"><spectrumList count="%d" defaultDataProcessingRef="dp">', length(specs))
  )
  writeLines(c(header, specs, c('</spectrumList>', '</run>', '</mzML>')), path)
  invisible(path)
}

# ------------------------------------------------------------
# mzXML writer
# ------------------------------------------------------------
pq_b64_be <- function(mzv, inv) {
  inter <- as.vector(t(cbind(as.double(mzv), as.double(inv))))
  base64enc::base64encode(writeBin(inter, raw(), size = 8, endian = "big"))
}

pq_write_mzxml <- function(path, file_tag = 1) {
  rts <- pq_fixture_scans()
  scans <- character(0)
  num <- 0L
  for (i in seq_along(rts)) {
    sp <- pq_fixture_spectrum(rts[i], file_tag)
    num <- num + 1L
    scans <- c(scans, sprintf(
      paste0('<scan num="%d" msLevel="1" peaksCount="%d" retentionTime="PT%.2fS" ',
             'polarity="negative" lowMz="100" highMz="1500">',
             '<peaks compressionType="none" compressedLen="0" precision="64" ',
             'byteOrder="network" contentType="m/z-int">%s</peaks></scan>'),
      num, length(sp$mz), rts[i] * 60, pq_b64_be(sp$mz, sp$intensity)))
    if (i %% 10 == 0) {
      num <- num + 1L
      scans <- c(scans, sprintf(
        paste0('<scan num="%d" msLevel="2" peaksCount="2" retentionTime="PT%.2fS" ',
               'polarity="negative"><precursorMz precursorIntensity="1200">301.1234</precursorMz>',
               '<peaks compressionType="none" compressedLen="0" precision="64" ',
               'byteOrder="network" contentType="m/z-int">%s</peaks></scan>'),
        num, rts[i] * 60, pq_b64_be(c(301.1234, 250.07), c(1200, 300))))
    }
  }

  txt <- c(
    '<?xml version="1.0" encoding="ISO-8859-1"?>',
    '<mzXML xmlns="http://sashimi.sourceforge.net/schema_revision/mzXML_3.2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://sashimi.sourceforge.net/schema_revision/mzXML_3.2 http://sashimi.sourceforge.net/schema_revision/mzXML_3.2.xsd">',
    sprintf('<msRun scanCount="%d">', num),
    scans, '</msRun>', '</mzXML>')
  writeLines(txt, path)
  invisible(path)
}

# ------------------------------------------------------------
# Peak tables in three different software flavours
# ------------------------------------------------------------
pq_fixture_features <- function(rt_unit = "min") {
  tr <- pq_fixture_truth()
  if (identical(rt_unit, "sec")) tr$rt <- tr$rt * 60
  data.frame(feature_id = tr$feature_id, mz = tr$mz, rt = tr$rt,
             sample_id = "S1", stringsAsFactors = FALSE)
}

pq_fixture_features_mzmine <- function() {
  tr <- pq_fixture_truth()
  # MZmine-ish names: "row ID", "row m/z", "row retention time", and no sample column
  data.frame(
    check.names = FALSE,
    `row ID` = seq_len(nrow(tr)),
    `row m/z` = tr$mz,
    `row retention time` = tr$rt,
    `peak area` = seq(1000, 7000, length.out = nrow(tr)),
    stringsAsFactors = FALSE
  )
}

pq_fixture_features_msdial <- function() {
  tr <- pq_fixture_truth()
  data.frame(
    check.names = FALSE,
    `Alignment ID` = seq_len(nrow(tr)),
    `Average Mz` = tr$mz,
    `Average Rt(min)` = tr$rt,
    `Metabolite name` = paste0("Met_", seq_len(nrow(tr))),
    `Adduct type` = "[M-H]-",
    `Fill %` = 100,
    stringsAsFactors = FALSE
  )
}

# ------------------------------------------------------------
# Build everything into `dir` and return the paths
# ------------------------------------------------------------
pq_fixture_make <- function(dir = file.path(tempdir(), "pq_fixtures")) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  mzml1 <- file.path(dir, "S1.mzML")
  mzml2 <- file.path(dir, "S2.mzML")
  mzxml1 <- file.path(dir, "S1_copy.mzXML")
  pq_write_mzml(mzml1, 1)
  pq_write_mzml(mzml2, 2)
  pq_write_mzxml(mzxml1, 1)

  f_min <- file.path(dir, "features_min.csv")
  f_sec <- file.path(dir, "features_sec.csv")
  f_mz  <- file.path(dir, "features_mzmine.csv")
  f_msd <- file.path(dir, "features_msdial.csv")
  write.csv(pq_fixture_features("min"), f_min, row.names = FALSE)
  write.csv(pq_fixture_features("sec"), f_sec, row.names = FALSE)
  write.csv(pq_fixture_features_mzmine(), f_mz, row.names = FALSE)
  write.csv(pq_fixture_features_msdial(), f_msd, row.names = FALSE)

  list(dir = dir, mzml = mzml1, mzml2 = mzml2, mzxml = mzxml1,
       features_min = f_min, features_sec = f_sec,
       features_mzmine = f_mz, features_msdial = f_msd,
       truth = pq_fixture_truth())
}
