#!/usr/bin/env python
"""Batch inference for a trained peak-group model.

Two jobs, kept separate on purpose:
  train  -> pq_dnn_train.py   (slow, once, produces a fixed .h5)
  apply  -> this script       (fast, repeatable, loads a frozen model)

That separation is a hard requirement: clicking around the Shiny UI must never
start a training run.

Input contract
--------------
A directory of peak-group matrices, one CSV per window, named `<feature_id>.csv`,
with no header — exactly what peakGroupImageMatrixAndPlot.R writes:

  * 30 sample rows + 1 marker row (31 rows)
  * 200 retention-time slices per row
  * zeros were exported as NA to save space, so NA reads back as 0
  * every cell is divided by the matrix maximum, so values lie in [0, 1]

The script does not care whether the matrices have 31x200 or some other shape;
it adapts to the shape the model was built for and refuses politely when the
shapes disagree.

Output
------
`<out>/dnn_predictions.csv`, one row per window that produced a score, plus one
row per window that did not, with the reason. A window that fails is never
silently dropped and never scored as zero.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_matrix(path: str):
    """Read a headerless matrix CSV, restoring the author's 0 <- NA step."""
    import numpy as np

    arr = np.genfromtxt(path, delimiter=",", dtype=np.float64)
    if arr.ndim == 1:
        arr = arr.reshape(1, -1)
    # peakGroupImageMatrixAndPlot.R:497 writes 0 as NA; ReadToMatrix puts 0 back
    arr = np.nan_to_num(arr, nan=0.0)
    return arr


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model", required=True, help="frozen .h5 produced by pq_dnn_train.py")
    ap.add_argument("--matrices", required=True, help="directory of <feature_id>.csv")
    ap.add_argument("--out", required=True)
    ap.add_argument("--threshold", type=float, default=0.5,
                    help="author's ApplyPeakPredictionModel.R uses 0.5")
    ap.add_argument("--limit", type=int, default=0,
                    help="optional cap on how many windows to score (0 = all)")
    args = ap.parse_args(argv)

    import numpy as np
    import tensorflow as tf
    from tensorflow import keras

    os.makedirs(args.out, exist_ok=True)

    files = sorted(f for f in os.listdir(args.matrices)
                   if f.lower().endswith(".csv"))
    if args.limit and args.limit > 0:
        files = files[:args.limit]

    meta = {
        "model": os.path.abspath(args.model),
        "model_sha256": sha256(args.model),
        "model_bytes": os.path.getsize(args.model),
        "tensorflow": tf.__version__,
        "keras": keras.__version__,
        "threshold": args.threshold,
        "n_files": len(files),
        "matrices_dir": os.path.abspath(args.matrices),
    }

    rows = []
    if not files:
        meta["status"] = "no_input_files"
        model = None
    else:
        try:
            model = keras.models.load_model(args.model, compile=False)
            meta["status"] = "ok"
        except Exception as exc:
            model = None
            meta["status"] = "model_load_failed"
            meta["error"] = str(exc)

    if model is not None:
        in_shape = model.input_shape          # (None, H, W, C)
        meta["input_shape"] = [None if v is None else int(v) for v in in_shape]
        want_h, want_w = int(in_shape[1]), int(in_shape[2])

    batch, names, bad = [], [], []
    for f in files:
        fid = os.path.splitext(f)[0]
        try:
            m = read_matrix(os.path.join(args.matrices, f))
        except Exception as exc:
            bad.append((fid, "unreadable", str(exc)))
            continue
        if model is None:
            bad.append((fid, meta.get("status", "model_unavailable"),
                        meta.get("error", "")))
            continue
        if m.shape != (want_h, want_w):
            bad.append((fid, "shape_mismatch",
                        f"got {m.shape}, model wants {(want_h, want_w)}"))
            continue
        batch.append(m)
        names.append(fid)

    if batch:
        X = np.stack(batch)[..., np.newaxis].astype("float32")
        # The author's -2 sentinel: cells that were NaN in training. Exported
        # matrices never contain NaN, so this is a guard rather than a step.
        X[~np.isfinite(X)] = -2
        # global scaling already happened upstream; do not renormalise here or
        # the model would see a distribution it was never trained on
        prob = model.predict(X, batch_size=64, verbose=0)
        if prob.ndim == 2 and prob.shape[1] == 2:
            score = prob[:, 1]                # author scores class 1
            meta["output_head"] = "softmax_2"
        else:
            score = prob.ravel()              # sigmoid head
            meta["output_head"] = "sigmoid_1"

        for fid, s in zip(names, score):
            rows.append({
                "feature_id": fid,
                "dnn_prediction": int(s >= args.threshold),
                "dnn_score": float(s),
                "dnn_threshold": args.threshold,
                "dnn_input_status": "ok",
                "dnn_error": "",
            })

    for fid, status, err in bad:
        rows.append({
            "feature_id": fid,
            "dnn_prediction": "",
            "dnn_score": "",
            "dnn_threshold": args.threshold,
            "dnn_input_status": status,
            "dnn_error": err,
        })

    out_csv = os.path.join(args.out, "dnn_predictions.csv")
    with open(out_csv, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=[
            "feature_id", "dnn_prediction", "dnn_score", "dnn_threshold",
            "dnn_input_status", "dnn_error"])
        w.writeheader()
        for r in rows:
            w.writerow(r)

    meta["n_scored"] = len(names)
    meta["n_failed"] = len(bad)
    with open(os.path.join(args.out, "dnn_predict_meta.json"), "w",
              encoding="utf-8") as fh:
        json.dump(meta, fh, indent=1, ensure_ascii=False)

    print("model status:", meta["status"])
    if model is not None:
        print("input shape :", meta["input_shape"], "head:", meta["output_head"])
    print("scored %d, failed %d" % (len(names), len(bad)))
    if bad[:5]:
        print("first failures:", bad[:5])
    print("wrote", out_csv)
    return 0 if model is not None else 2


if __name__ == "__main__":
    sys.exit(main())
