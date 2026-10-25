#!/usr/bin/env python
"""Reproduce the author's DNN training run.

Origin
------
This is a faithful port of `EDML_deep_learning2.py` as published in
MassIVE MSV000084186 (file `other/TrainTestCalibrationData/EDML_deep_learning2.py`,
5,106 bytes) and in the GitHub repository at commit 94237bf.

What is preserved exactly
-------------------------
  * input array names and shapes read from the .mat file
  * NaN -> -2 imputation
  * class count 2, one-hot targets via to_categorical
  * layer stack: Conv2D(32,3x3,same) -> MaxPool(2) -> Dropout(0.2)
                 Conv2D(16,3x3)          -> MaxPool(2) -> Dropout(0.2)
                 Flatten -> Dense(64,relu) -> Dropout(0.5) -> Dense(2,softmax)
  * loss categorical_crossentropy, optimizer nadam, batch 128, epochs 500,
    EarlyStopping(monitor=val_loss, patience=10, restore_best_weights=True)
  * scoring index [:, 1] for the "good peak" class

What had to change, and why
---------------------------
  * `from keras.utils import multi_gpu_model` — removed. The API existed only in
    Keras 2.1-2.2 and was deleted in Keras 3. The MassIVE copy of the script
    calls it, so that copy cannot run on any current Keras. Removing it changes
    how the work is parallelised, not what the network computes. Recorded in the
    reproduction report as a known deviation.
  * `from keras.utils.vis_utils import plot_model` — moved to
    `tf.keras.utils.plot_model` in Keras 2.6+; the call is wrapped in try/except
    because graphviz is not installed here and the plot is diagnostic only.
  * `from IPython.display import clear_output` — imported but never called in the
    original; dropped.
  * absolute Windows paths (`D:\\Projects\\P9_EDML\\...`) — replaced by CLI args.
  * a fixed seed — the original had none, so a rerun was not reproducible.

Nothing about the architecture, the data split or the label meaning is altered.
If you need to convince yourself, diff this file against the original; every
difference is listed above.

Usage
-----
    python pq_dnn_train.py --mat ../../source_data/EDML_trainTestCalData15.mat \
                           --out ../models --epochs 500
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import random
import sys
import time

# Keep TensorFlow quiet before it is imported; the oneDNN chatter is noise here.
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_mat(path: str) -> dict:
    """Read the .mat with h5py, exactly as the author does.

    The author's line is `h5py.File('EDML_trainTestCalData15.mat','r')`, which
    only works for MATLAB v7.3 (HDF5) files. If this raises, the file is not the
    format the script expects and no amount of tuning will fix it.
    """
    import h5py
    import numpy as np

    arrays = {}
    with h5py.File(path, "r") as fh:
        for k, v in fh.items():
            arrays[k] = np.array(v)
    return arrays


def build_model(input_shape, learning_rate=None):
    """The author's layer stack, transcribed one layer at a time."""
    from tensorflow import keras
    from tensorflow.keras import layers

    model = keras.Sequential()
    model.add(layers.Conv2D(32, kernel_size=(3, 3), activation="relu",
                            padding="same", input_shape=input_shape))
    model.add(layers.MaxPooling2D(pool_size=(2, 2)))
    model.add(layers.Dropout(0.2))

    model.add(layers.Conv2D(16, kernel_size=(3, 3), activation="relu"))
    model.add(layers.MaxPooling2D(pool_size=(2, 2)))
    model.add(layers.Dropout(0.2))

    model.add(layers.Flatten())
    model.add(layers.Dense(64, activation="relu"))
    model.add(layers.Dropout(0.5))
    model.add(layers.Dense(2, activation="softmax"))

    model.compile(loss="categorical_crossentropy",
                  optimizer="nadam",
                  metrics=["mse", "accuracy"])
    return model


def metrics_at(y_true, score, threshold):
    """Confusion-matrix derived metrics using the author's convention.

    label 1 = acceptable peak (the author's "good"), label 0 = bad.
    Positive class is 1, matching roc_curve(y[:,1], pred[:,1]).
    """
    import numpy as np
    from sklearn.metrics import roc_auc_score, roc_curve

    y_true = np.asarray(y_true).astype(int).ravel()
    pred = (np.asarray(score).ravel() >= threshold).astype(int)

    tp = int(np.sum((y_true == 1) & (pred == 1)))
    fn = int(np.sum((y_true == 1) & (pred == 0)))
    tn = int(np.sum((y_true == 0) & (pred == 0)))
    fp = int(np.sum((y_true == 0) & (pred == 1)))

    def safe(a, b):
        return float(a) / float(b) if b else float("nan")

    out = {
        "n": int(len(y_true)),
        "n_pos": int(np.sum(y_true == 1)),
        "n_neg": int(np.sum(y_true == 0)),
        "threshold": float(threshold),
        "tp": tp, "fp": fp, "tn": tn, "fn": fn,
        "sensitivity": safe(tp, tp + fn),
        "specificity": safe(tn, tn + fp),
        "precision": safe(tp, tp + fp),
        "npv": safe(tn, tn + fn),
        "accuracy": safe(tp + tn, len(y_true)),
        "f1": safe(2 * tp, 2 * tp + fp + fn),
    }
    try:
        out["auc"] = float(roc_auc_score(y_true, np.asarray(score).ravel()))
        fpr, tpr, thr = roc_curve(y_true, np.asarray(score).ravel())
        # the author's `coords(roc, "best", best.method = "closest.topleft")`
        d = (1 - tpr) ** 2 + fpr ** 2
        i = int(np.argmin(d))
        out["threshold_topleft"] = float(thr[i])
        out["topleft_tpr"] = float(tpr[i])
        out["topleft_fpr"] = float(fpr[i])
    except Exception as exc:                      # single-class data
        out["auc"] = float("nan")
        out["auc_error"] = str(exc)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mat", default="../../source_data/EDML_trainTestCalData15.mat")
    ap.add_argument("--out", default="../models")
    ap.add_argument("--epochs", type=int, default=500,
                    help="author used 500 with patience 10")
    ap.add_argument("--patience", type=int, default=10,
                    help="author used 10")
    ap.add_argument("--batch-size", type=int, default=128, help="author used 128")
    ap.add_argument("--seed", type=int, default=20190301)
    ap.add_argument("--tag", default="edml15")
    args = ap.parse_args(argv)

    import numpy as np
    import tensorflow as tf
    from tensorflow import keras
    from tensorflow.keras.utils import to_categorical

    t0 = time.time()
    started = time.strftime("%Y-%m-%d %H:%M:%S")

    random.seed(args.seed)
    np.random.seed(args.seed)
    tf.random.set_seed(args.seed)

    os.makedirs(args.out, exist_ok=True)
    log_path = os.path.join(args.out, f"{args.tag}_train_log.json")
    log = {
        "started": started,
        "argv": sys.argv,
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "tensorflow": tf.__version__,
        "keras": keras.__version__,
        "numpy": np.__version__,
        "seed": args.seed,
        "mat": os.path.abspath(args.mat),
        "mat_sha256": sha256(args.mat),
        "mat_bytes": os.path.getsize(args.mat),
        "deviations": [
            "multi_gpu_model removed (API deleted in Keras 3); affects "
            "parallelism only, not the computation",
            "plot_model import moved to tf.keras.utils and made optional",
            "IPython.display.clear_output import dropped (was unused)",
            "absolute paths replaced by CLI arguments",
            "fixed seed added for reproducibility (original had none)",
        ],
    }

    # ---- data, exactly as the author loads it -----------------------------
    arrays = load_mat(args.mat)
    log["mat_keys"] = sorted(arrays.keys())

    Xtrain = arrays["trainX"]
    yTrain = arrays["trainY"]
    yTrain = yTrain.reshape(yTrain.shape[1], 1)
    yTrain = to_categorical(yTrain.astype("uint8"), num_classes=2)
    Xtrain[np.isnan(Xtrain)] = -2
    Xtrain = Xtrain.reshape(Xtrain.shape[0], Xtrain.shape[1], Xtrain.shape[2], 1)

    XTest = arrays["testX"]
    yTest = arrays["testY"]
    yTest = yTest.reshape(yTest.shape[1], 1)
    yTest = to_categorical(yTest.astype("uint8"), num_classes=2)
    XTest[np.isnan(XTest)] = -2
    XTest = XTest.reshape(XTest.shape[0], XTest.shape[1], XTest.shape[2], 1)

    calX = arrays["calX"]
    calY = arrays["calY"]
    calY = calY.reshape(calY.shape[1], 1)
    calY = to_categorical(calY.astype("uint8"), num_classes=2)
    calX[np.isnan(calX)] = -2
    calX = calX.reshape(calX.shape[0], calX.shape[1], calX.shape[2], 1)

    log["shapes"] = {
        "trainX": list(Xtrain.shape), "trainY": list(yTrain.shape),
        "calX": list(calX.shape), "calY": list(calY.shape),
        "testX": list(XTest.shape), "testY": list(yTest.shape),
    }
    log["class_balance"] = {
        "train": [int(v) for v in np.bincount(np.argmax(yTrain, axis=1), minlength=2)],
        "cal": [int(v) for v in np.bincount(np.argmax(calY, axis=1), minlength=2)],
        "test": [int(v) for v in np.bincount(np.argmax(yTest, axis=1), minlength=2)],
    }
    # the author's -2 sentinel is a real cell value, so record how often it occurs
    log["sentinel"] = {
        "value": -2,
        "train_frac": float(np.mean(Xtrain == -2)),
        "cal_frac": float(np.mean(calX == -2)),
        "test_frac": float(np.mean(XTest == -2)),
        "train_min": float(Xtrain.min()), "train_max": float(Xtrain.max()),
    }
    print("shapes:", log["shapes"])
    print("class balance:", log["class_balance"])

    # ---- model ------------------------------------------------------------
    model = build_model((Xtrain.shape[1], Xtrain.shape[2], 1))
    model.summary(print_fn=lambda s, **kw: print(s))
    log["n_params"] = int(model.count_params())

    ckpt = os.path.join(args.out, f"{args.tag}_best.weights.h5")
    callbacks = [
        keras.callbacks.EarlyStopping(monitor="val_loss", patience=args.patience,
                                      restore_best_weights=True),
        keras.callbacks.ModelCheckpoint(ckpt, monitor="val_loss",
                                        save_best_only=True),
    ]

    hist = model.fit(Xtrain, yTrain,
                     validation_data=(calX, calY),
                     epochs=args.epochs,
                     batch_size=args.batch_size,
                     callbacks=callbacks,
                     verbose=2)
    log["epochs_run"] = int(len(hist.history.get("loss", [])))
    log["history"] = {k: [float(x) for x in v] for k, v in hist.history.items()}

    # ---- evaluation, on the split the author calls "test" ------------------
    def score_of(X):
        return model.predict(X, verbose=0)[:, 1]

    s_train = score_of(Xtrain)
    s_cal = score_of(calX)
    s_test = score_of(XTest)

    yt_train = np.argmax(yTrain, axis=1)
    yt_cal = np.argmax(calY, axis=1)
    yt_test = np.argmax(yTest, axis=1)

    evals = {
        "train": metrics_at(yt_train, s_train, 0.5),
        "cal": metrics_at(yt_cal, s_cal, 0.5),
        "test": metrics_at(yt_test, s_test, 0.5),
    }
    # also report at each split's own topleft threshold, since the author's
    # filter script uses a tuned threshold rather than 0.5
    for split, yt, sc in (("train", yt_train, s_train),
                          ("cal", yt_cal, s_cal),
                          ("test", yt_test, s_test)):
        thr = evals[split].get("threshold_topleft")
        if thr is not None and np.isfinite(thr):
            evals[split + "_at_topleft"] = metrics_at(yt, sc, thr)

    log["evaluation"] = evals
    for k in ("train", "cal", "test"):
        e = evals[k]
        print("%-5s n=%d auc=%.4f sens=%.3f spec=%.3f prec=%.3f acc=%.3f"
              % (k, e["n"], e["auc"], e["sensitivity"], e["specificity"],
                 e["precision"], e["accuracy"]))

    # ---- save -------------------------------------------------------------
    h5 = os.path.join(args.out, f"{args.tag}.h5")
    model.save(h5)
    log["model_path"] = h5
    log["model_sha256"] = sha256(h5)
    log["model_bytes"] = os.path.getsize(h5)
    log["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    log["wall_seconds"] = round(time.time() - t0, 1)

    # a reload check: a model that cannot be loaded is not a usable model
    try:
        reloaded = keras.models.load_model(h5)
        probe = reloaded.predict(XTest[:8], verbose=0)
        again = model.predict(XTest[:8], verbose=0)
        log["reload_ok"] = True
        log["reload_shape"] = list(probe.shape)
        log["reload_max_abs_diff"] = float(np.max(np.abs(probe - again)))
        log["reload_finite"] = bool(np.all(np.isfinite(probe)))
    except Exception as exc:
        log["reload_ok"] = False
        log["reload_error"] = str(exc)

    with open(log_path, "w", encoding="utf-8") as fh:
        json.dump(log, fh, indent=1, ensure_ascii=False)

    print("\nwall: %.1fs" % (time.time() - t0))
    print("model:", h5)
    print("log  :", log_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
