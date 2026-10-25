#!/usr/bin/env python
"""Build DNN_reference/DATA_MANIFEST.csv — every downloaded asset with SHA-256.

Run from the DNN_reference directory. Re-running is safe: it rewrites the CSV
from whatever is currently on disk, so a partial download shows up as a smaller
byte count rather than a silently wrong record.
"""
import csv
import hashlib
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# file -> (where it came from, what it is)
SOURCES = {
    "source_code/repo": (
        "https://github.com/JainLab/Manuscript-DNNs-for-Classification-of-LCMS-Peaks.git",
        "author code, git clone, commit 94237bf45e790a8332e45a2f2842116f46a18aa9",
    ),
    "source_data/EDML_trainTestCalData15.mat": (
        "https://massive.ucsd.edu/ProteoSAFe/DownloadResultFile?file=f.MSV000084186%2Fother%2FTrainTestCalibrationData%2FEDML_trainTestCalData15.mat",
        "pixel arrays: trainX/trainY, testX/testY, calX/calY (paper reproduction set)",
    ),
    "source_data/EDML_deep_learning2.py": (
        "https://massive.ucsd.edu/ProteoSAFe/DownloadResultFile?file=f.MSV000084186%2Fother%2FTrainTestCalibrationData%2FEDML_deep_learning2.py",
        "author working copy of the training script; differs from the GitHub version",
    ),
    "source_data/params.xml": (
        "https://massive.ucsd.edu/ProteoSAFe/DownloadResultFile?file=f.MSV000084186%2Fccms_parameters%2Fparams.xml",
        "MassIVE processing parameters for the dataset",
    ),
}

EXPECTED = {
    "source_data/EDML_trainTestCalData15.mat": 25797944,
    "source_data/EDML_deep_learning2.py": 5106,
    "source_data/params.xml": 107346,
}


def sha256(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def main():
    rows = []
    for key, (url, what) in SOURCES.items():
        target = os.path.join(ROOT, key)
        if not os.path.exists(target):
            rows.append([key, "", "", "MISSING", url, what, "", ""])
            continue
        if os.path.isdir(target):
            # a git clone: the identity of a checkout is its commit, not its bytes
            import subprocess
            try:
                commit = subprocess.check_output(
                    ["git", "-C", target, "rev-parse", "HEAD"],
                    text=True).strip()
            except Exception:
                commit = ""
            rows.append([
                key + "/", "", commit, "git clone", url, what,
                "Univ. of California (research / non-profit)",
                "LICENSE.txt",
            ])
            continue
        size = os.path.getsize(target)
        exp = EXPECTED.get(key)
        status = "ok"
        if exp is not None and size != exp:
            status = "INCOMPLETE (expected %d)" % exp
        rows.append([key, size, sha256(target), status, url, what,
                     "CC0 1.0 Universal", "MassIVE MSV000084186"])

    out = os.path.join(ROOT, "DATA_MANIFEST.csv")
    with open(out, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["file", "bytes", "sha256_or_commit", "status", "source_url",
                    "description", "license", "license_source"])
        for r in rows:
            w.writerow(r)

    print("wrote", out)
    for r in rows:
        print("  %-46s %12s  %s" % (r[0], r[1], r[3]))
    print("\ncode commit:", "94237bf45e790a8332e45a2f2842116f46a18aa9")
    print("dataset    : MassIVE MSV000084186, 1222 files, 13.78 GB, CC0 1.0")
    print("retrieved  :", time.strftime("%Y-%m-%d %H:%M:%S"))
    print("note       : the dataset is CC0; the CODE is not. See LICENSE.txt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
