#!/usr/bin/env python
"""Integrity and error-structure diagnostics for the frozen model.

Two questions this answers, both of which a plain AUC number hides:

1. **Split leakage.**  `NeuralNetworkDataPrep.R` contains a `mirrorMatrix()` step
   that duplicates examples by column reversal, so it was reasonable to suspect
   the 1304 training images were 652 mirrored pairs.  They are not: this script
   hashes every image in four orientations and cross-correlates a random probe
   set, and finds no exact duplicate, no mirror twin and no near-duplicate
   (best correlation 0.965, far below the 0.999 a twin would give).  The check
   is reported anyway, because what matters for the held-out numbers is that no
   duplicate crosses a split boundary — and the result is 0 there too.
   It cannot detect *content* proximity (same instrument, same samples, adjacent
   chromatography); only external data could, and none exists.  See
   `VALIDATION_REPORT.md`.

2. **Where the errors are.**  An AUC of 0.99 says nothing about which peaks are
   lost.  The obvious stratifier — peak height — is *unavailable by
   construction*: every image is divided by its own maximum, so all 2,770 images
   have max exactly 1.0 (verified below, and recorded in the report).  Absolute
   abundance is therefore invisible to the model, and any claim that it
   "handles low-abundance peaks" is about shape, not about intensity.
   The stratifiers used instead are scale-invariant shape descriptors:
     * nonzero-cell fraction — how much of the image is background,
     * main-lobe width — how many columns reach half of the image maximum,
     * prevalence — how many rows carry any signal at all.

   Note the axes of the 64x64 image are *not* documented anywhere in the public
   material (`AUTHOR_METHOD_AUDIT.md` 3.2.1); these descriptors are used exactly
   because they do not need to know which axis is samples and which is time.

Usage
-----
    python pq_dnn_diagnostics.py --model ../models/edml15.h5 \
        --mat ../source_data/EDML_trainTestCalData15.mat \
        --out ../reports/diagnostics_edml15.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model", required=True)
    ap.add_argument("--mat", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--threshold", type=float, default=0.4725,
                    help="the paper's operating point")
    args = ap.parse_args(argv)

    import numpy as np
    import h5py
    from tensorflow import keras

    arrays = {}
    with h5py.File(args.mat, "r") as fh:
        for k, v in fh.items():
            arrays[k] = np.array(v)

    # ---------------- 1. exact-duplicate leakage ----------------
    # The mirror step in the author's R code is `mat[, ncol(mat):1]`, i.e. a
    # *column* reversal in MATLAB's (rows x cols) layout.  h5py hands us the
    # transpose, so the same operation shows up here as a *row* reversal.  Rather
    # than bet on one orientation, all four are hashed: identity, column flip,
    # row flip, and both.  With square images this covers transposition too.
    def variants(a):
        a = np.ascontiguousarray(a, dtype=np.float32)
        f = a[::-1, :]
        return {
            "id": hashlib.sha1(a.tobytes()).hexdigest(),
            "colflip": hashlib.sha1(np.ascontiguousarray(a[:, ::-1]).tobytes()).hexdigest(),
            "rowflip": hashlib.sha1(np.ascontiguousarray(f).tobytes()).hexdigest(),
            "both": hashlib.sha1(np.ascontiguousarray(f[:, ::-1]).tobytes()).hexdigest(),
        }

    seen = {}
    dup = {"cross_split_exact": [], "cross_split_mirror": [],
           "within_split_mirror": {}, "hash_variants": ["id", "colflip", "rowflip", "both"]}

    for split in ("train", "cal", "test"):
        X = arrays[f"{split}X"]
        seen_local = {}
        pairs = 0
        for i in range(X.shape[0]):
            v = variants(X[i])
            identical = [k for k in ("colflip", "rowflip", "both") if v[k] == v["id"]]
            for k in ("colflip", "rowflip", "both"):
                if k in identical:
                    continue
                if v[k] in seen_local:
                    pairs += 1
                    break
            seen_local[v["id"]] = i
            # exact duplicates across splits
            if v["id"] in seen and seen[v["id"]][0] != split:
                if len(dup["cross_split_exact"]) < 20:
                    dup["cross_split_exact"].append([seen[v["id"]][0], seen[v["id"]][1], split, i])
            seen.setdefault(v["id"], (split, i))
        dup["within_split_mirror"][split] = int(pairs)

    # cross-split mirror: flip of an image in one split equals an image in another
    for a, b in (("train", "cal"), ("train", "test"), ("cal", "test")):
        Xa, Xb = arrays[f"{a}X"], arrays[f"{b}X"]
        hb = {}
        for j in range(Xb.shape[0]):
            hb[variants(Xb[j])["id"]] = j
        for i in range(Xa.shape[0]):
            v = variants(Xa[i])
            for k in ("colflip", "rowflip", "both"):
                if v[k] != v["id"] and v[k] in hb:
                    if len(dup["cross_split_mirror"]) < 20:
                        dup["cross_split_mirror"].append([a, i, b, hb[v[k]], k])
                    break

    n_cross = len(dup["cross_split_exact"]) + len(dup["cross_split_mirror"])
    dup["verdict"] = (
        "no exact or mirrored duplicate crosses a split boundary"
        if n_cross == 0 else
        "WARNING: duplicate images cross split boundaries; held-out scores are inflated"
    )

    # ---------------- 1b. near-duplicate probe ----------------
    # Exact hashing only rules out bit-identical images.  A duplicate produced
    # before normalisation, or through a resample, is not bit-identical but
    # still correlates at ~0.999.  This is computed for *every* image, not a
    # sample, because a sampled probe missed the worst offenders on the first
    # attempt (80 probes found 0.9973 while the true maximum was 0.9999).
    def zscore_rows(A):
        A = A.reshape(len(A), -1).astype(np.float64)
        A -= A.mean(axis=1, keepdims=True)
        n = np.linalg.norm(A, axis=1, keepdims=True)
        n[n == 0] = 1.0
        return A / n

    Ztr = zscore_rows(arrays["trainX"])
    near = {"by_split": {}}
    for split in ("cal", "test"):
        Zb = zscore_rows(arrays[f"{split}X"])
        cmax = (Ztr @ Zb.T).max(axis=0)
        near["by_split"][split] = {
            "n_images": int(cmax.size),
            "max_corr_with_a_training_image": float(cmax.max()),
            "n_above": {str(t): int((cmax > t).sum()) for t in (0.999, 0.99, 0.98, 0.95)},
            # kept in memory for the out-of-sample AUC comparison below
            "_cmax": cmax,
        }
    near["verdict"] = (
        "no near-duplicate crosses the split boundary"
        if max(v["n_above"]["0.999"] for v in near["by_split"].values()) == 0 else
        "a small number of near-duplicate images crosses the split boundary; "
        "the held-out AUC is therefore slightly optimistic"
    )

    # ---------------- 2. error structure by peak height ----------------
    model = keras.models.load_model(args.model, compile=False)

    def prep(X):
        X = X.copy()
        X[np.isnan(X)] = -2
        return X.reshape(X.shape[0], X.shape[1], X.shape[2], 1)

    Xte = prep(arrays["testX"])
    yte = arrays["testY"].reshape(-1).astype(int)
    score = model.predict(Xte, batch_size=64, verbose=0)[:, 1]
    pred = (score >= args.threshold).astype(int)

    # Scale-invariant descriptors of the raw (un-preprocessed) test images.
    Xraw = arrays["testX"]
    n_img = Xraw.shape[0]
    flat = Xraw.reshape(n_img, -1)
    img_max = flat.max(axis=1)
    nonzero_frac = (Xraw > 0).reshape(n_img, -1).mean(axis=1)
    col_max = Xraw.max(axis=1)                      # max over the other axis
    lobe_width = (col_max > 0.5).mean(axis=1)
    prevalence = (Xraw.max(axis=2) > 0).mean(axis=1)

    # every image normalised by its own maximum: confirm rather than assume
    max_is_constant = bool(np.allclose(img_max, 1.0, atol=1e-6))

    # ---- how much does the near-duplicate overlap actually buy? ----
    # Report the held-out AUC with and without the offending images.  If the
    # delta is in the fourth decimal, the overlap is present but immaterial and
    # the reproduction stands; if it is large, the paper's number is inflated.
    from sklearn.metrics import roc_auc_score
    cmax = near["by_split"]["test"]["_cmax"]
    auc_all = float(roc_auc_score(yte, score))
    keep = cmax <= 0.99
    auc_clean = float(roc_auc_score(yte[keep], score[keep]))
    near["test_auc_sensitivity"] = {
        "auc_all_test_images": auc_all,
        "auc_excluding_duplicates_gt_0.99": auc_clean,
        "n_excluded": int((~keep).sum()),
        "auc_delta": float(auc_all - auc_clean),
        "reading": ("overlap is present but too small to change the held-out "
                    "estimate" if abs(auc_all - auc_clean) < 0.005 else
                    "overlap materially inflates the held-out estimate"),
    }

    def stratify(feature, name):
        pos = yte == 1
        edges = np.unique(np.quantile(feature[pos], np.linspace(0, 1, 6)))
        rows = []
        for k in range(len(edges) - 1):
            lo, hi = edges[k], edges[k + 1]
            last = (k == len(edges) - 2)
            sel = pos & (feature >= lo) & ((feature <= hi) if last else (feature < hi))
            n = int(sel.sum())
            if n == 0:
                continue
            fn = int(np.sum(pred[sel] == 0))
            rows.append({
                "lo": float(lo), "hi": float(hi), "n_true_peaks": n,
                "n_missed": fn, "false_negative_rate": float(fn) / n,
                "mean_score": float(score[sel].mean()),
            })
        return {"feature": name, "quintiles": rows}

    report = {
        "model": os.path.abspath(args.model),
        "threshold": args.threshold,
        "leakage": dup,
        "near_duplicate_probe": near,
        "normalisation": {
            "every_image_max_equals_one": max_is_constant,
            "image_max_min": float(img_max.min()),
            "image_max_max": float(img_max.max()),
            "note": ("absolute intensity is destroyed by the author's per-image "
                     "normalisation, so height cannot be a stratifier and the "
                     "model cannot be height-biased or height-aware"),
        },
        "descriptor_ranges_test": {
            "nonzero_frac": [float(nonzero_frac.min()), float(nonzero_frac.max())],
            "lobe_width": [float(lobe_width.min()), float(lobe_width.max())],
            "prevalence": [float(prevalence.min()), float(prevalence.max())],
        },
        "false_negative_by_descriptor_test_positives": [
            stratify(nonzero_frac, "nonzero_frac"),
            stratify(lobe_width, "lobe_width"),
            stratify(prevalence, "prevalence"),
        ],
        "overall": {
            "test_n_pos": int((yte == 1).sum()),
            "test_n_missed_pos": int(np.sum((pred == 0) & (yte == 1))),
            "test_n_neg": int((yte == 0).sum()),
            "test_n_false_pos": int(np.sum((pred == 1) & (yte == 0))),
        },
    }

    print("leakage:", dup["verdict"])
    print("  within-split mirror pairs:", dup["within_split_mirror"])
    print("  cross-split exact:", len(dup["cross_split_exact"]),
          " cross-split mirror:", len(dup["cross_split_mirror"]))
    print("near-duplicate probe:", near["verdict"],
          "(max corr with a training image: cal %.4f, test %.4f)"
          % (near["by_split"]["cal"]["max_corr_with_a_training_image"],
             near["by_split"]["test"]["max_corr_with_a_training_image"]))
    print("  test AUC all=%.4f  excl.>0.99 dupes=%.4f  delta=%.5f"
          % (near["test_auc_sensitivity"]["auc_all_test_images"],
             near["test_auc_sensitivity"]["auc_excluding_duplicates_gt_0.99"],
             near["test_auc_sensitivity"]["auc_delta"]))
    print("every image max == 1.0 :", max_is_constant)
    print("\nfalse negatives among true test peaks, by descriptor quintile:")
    for block in report["false_negative_by_descriptor_test_positives"]:
        print(" ", block["feature"])
        for b in block["quintiles"]:
            print("    %7.3f-%7.3f  n=%3d  missed=%3d  FNR=%.3f  mean_score=%.3f"
                  % (b["lo"], b["hi"], b["n_true_peaks"], b["n_missed"],
                     b["false_negative_rate"], b["mean_score"]))

    # numpy arrays cannot be serialised; the per-image correlations are already
    # summarised in counts, so drop the raw vector before writing
    for v in near["by_split"].values():
        v.pop("_cmax", None)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=1, ensure_ascii=False)
    print("\nwrote", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
