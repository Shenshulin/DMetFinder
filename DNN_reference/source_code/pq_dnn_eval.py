#!/usr/bin/env python
"""Evaluate a frozen model on a .mat split, at the exact thresholds the paper quotes.

Why this exists separately from the training script
---------------------------------------------------
Training reports metrics at 0.5 and at each split's own "closest topleft"
threshold.  The paper, however, quotes its headline numbers at one specific
threshold: **0.4725**, chosen on the calibration set.  Comparing our run to the
paper therefore requires scoring at 0.4725, not at 0.5 — and that comparison
must not be done inside the training run, because then the reported threshold
would depend on the split being scored.

This script also serves as a reproducibility check.  It loads the frozen `.h5`
from disk and recomputes every metric from scratch.  If the numbers differ from
the training log, either the weights did not survive the round-trip or the
preprocessing did not, and both are fatal.

Usage
-----
    python pq_dnn_eval.py --model ../models/edml15.h5 \
                          --mat ../source_data/EDML_trainTestCalData15.mat \
                          --out ../reports/eval_edml15.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

# Thresholds reported on.  0.4725 is the paper's selected operating point;
# 0.4 is what filterOutBadPeaks.R defaults to; 0.5 is ApplyPeakPredictionModel.R.
PAPER_THRESHOLD = 0.4725
REFERENCE_THRESHOLDS = (0.4, 0.4725, 0.5, 0.6, 0.7)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def metrics_at(y_true, score, threshold):
    """TPR is called sensitivity and TNR is called specificity, as in the paper.

    The paper reports a false positive *rate*, which is 1 - specificity; both are
    emitted so the comparison needs no mental arithmetic.
    """
    import numpy as np

    y_true = np.asarray(y_true).astype(int).ravel()
    score = np.asarray(score).ravel()
    pred = (score >= threshold).astype(int)

    tp = int(np.sum((y_true == 1) & (pred == 1)))
    fn = int(np.sum((y_true == 1) & (pred == 0)))
    tn = int(np.sum((y_true == 0) & (pred == 0)))
    fp = int(np.sum((y_true == 0) & (pred == 1)))

    def div(a, b):
        return float(a) / float(b) if b else float("nan")

    return {
        "threshold": float(threshold),
        "n": int(len(y_true)), "n_pos": int(np.sum(y_true == 1)),
        "n_neg": int(np.sum(y_true == 0)),
        "tp": tp, "fp": fp, "tn": tn, "fn": fn,
        "tpr": div(tp, tp + fn),
        "fpr": div(fp, fp + tn),
        "specificity": div(tn, tn + fp),
        "precision": div(tp, tp + fp),
        "accuracy": div(tp + tn, len(y_true)),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model", required=True)
    ap.add_argument("--mat", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--splits", default="train,cal,test")
    args = ap.parse_args(argv)

    import numpy as np
    import h5py
    from tensorflow import keras

    model = keras.models.load_model(args.model, compile=False)
    in_shape = tuple(model.input_shape[1:])

    arrays = {}
    with h5py.File(args.mat, "r") as fh:
        for k, v in fh.items():
            arrays[k] = np.array(v)

    report = {
        "model": os.path.abspath(args.model),
        "model_sha256": sha256(args.model),
        "model_input_shape": [int(v) for v in in_shape],
        "mat_sha256": sha256(args.mat),
        "paper_threshold": PAPER_THRESHOLD,
        "splits": {},
    }

    for split in [s.strip() for s in args.splits.split(",") if s.strip()]:
        X = arrays[f"{split}X"]
        y = arrays[f"{split}Y"].reshape(-1)

        # identical preprocessing to the training script; anything else would
        # be scoring the model on a distribution it never saw
        X = X.copy()
        X[np.isnan(X)] = -2
        X = X.reshape(X.shape[0], X.shape[1], X.shape[2], 1)

        score = model.predict(X, batch_size=64, verbose=0)[:, 1]

        entry = {
            "n": int(len(y)),
            "class_balance": [int(np.sum(y == 0)), int(np.sum(y == 1))],
            "score_range": [float(score.min()), float(score.max())],
            "score_mean_by_class": {
                "label0": float(score[y == 0].mean()),
                "label1": float(score[y == 1].mean()),
            },
            "at_threshold": {},
        }
        for thr in REFERENCE_THRESHOLDS:
            entry["at_threshold"][str(thr)] = metrics_at(y, score, thr)
        report["splits"][split] = entry
        print("%-5s n=%d  paper-thr(%.4f) TPR=%.4f FPR=%.4f acc=%.4f"
              % (split, len(y), PAPER_THRESHOLD,
                 entry["at_threshold"][str(PAPER_THRESHOLD)]["tpr"],
                 entry["at_threshold"][str(PAPER_THRESHOLD)]["fpr"],
                 entry["at_threshold"][str(PAPER_THRESHOLD)]["accuracy"]))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=1, ensure_ascii=False)
    print("wrote", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
