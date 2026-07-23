#!/usr/bin/env python3
"""Train the classifier head on extracted feature vectors and rebuild the model.

This is the second phase of the workaround for Create ML's headless pixel-buffer
crash (see Tools/README.md). `extract_features.swift` has already turned every
photo into a 768-float VisionFeaturePrint.Scene vector; here we:

  1. train a multinomial logistic regression on those vectors (fast, no images);
  2. drop its weights into the glmClassifier of a Create ML model used as a
     template, so the on-disk format is byte-for-byte what Create ML produces;
  3. keep the template's VisionFeaturePrint.Scene stage untouched.

The result is an ordinary image-classifier .mlmodel: same pipeline shape the app
already consumes, so nothing in the app changes.

Usage:
    python3 Tools/compose_model.py <features.bin> <template.mlmodel> <out.mlmodel>
"""

from __future__ import annotations

import struct
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import numpy as np
import coremltools as ct
from sklearn.linear_model import LogisticRegression

FEATURES = 768


def load(bin_path: Path) -> tuple[np.ndarray, np.ndarray, list[str]]:
    labels = (bin_path.with_suffix(bin_path.suffix + ".labels.txt")
              .read_text().splitlines())
    record = 4 + FEATURES * 4
    raw = bin_path.read_bytes()
    assert len(raw) % record == 0, "corrupt feature file"
    n = len(raw) // record
    y = np.empty(n, dtype=np.int64)
    X = np.empty((n, FEATURES), dtype=np.float32)
    for i in range(n):
        base = i * record
        y[i] = struct.unpack_from("<I", raw, base)[0]
        X[i] = struct.unpack_from(f"<{FEATURES}f", raw, base + 4)
    return X, y, labels


def main() -> None:
    features_path = Path(sys.argv[1])
    template_path = Path(sys.argv[2])
    out_path = Path(sys.argv[3])

    X, y, labels = load(features_path)
    present = sorted(set(int(v) for v in y))
    print(f"{len(X)} vectors, {len(present)}/{len(labels)} classes present")

    # A class with too few examples cannot be learned and only destabilises the
    # softmax; drop it and let the worldwide model cover that species.
    counts = np.bincount(y, minlength=len(labels))
    keep = [c for c in present if counts[c] >= 15]
    dropped = [labels[c] for c in present if counts[c] < 15]
    if dropped:
        print(f"dropping {len(dropped)} sparse classes: {', '.join(dropped[:8])}"
              + (" …" if len(dropped) > 8 else ""))
    mask = np.isin(y, keep)
    X, y = X[mask], y[mask]

    # Re-index the surviving classes to a dense 0..K-1 range.
    remap = {old: new for new, old in enumerate(keep)}
    y = np.array([remap[int(v)] for v in y], dtype=np.int64)
    kept_labels = [labels[c] for c in keep]
    K = len(kept_labels)

    # Standardise per feature (global mean/std, NOT per-sample): the solver
    # converges far better on standardised inputs, and because the transform is
    # affine and identical for every image it folds exactly into the linear
    # weights below — so the model needs no extra runtime step and stays a plain
    # w·x + b over the raw feature print. (A per-sample L2 norm would NOT fold and
    # would silently break inference.)
    mu = X.mean(axis=0)
    sigma = X.std(axis=0)
    sigma[sigma == 0] = 1
    Xs = (X - mu) / sigma

    # Strong regularisation on purpose: 768 features × K classes overfits hard
    # otherwise (C=10 memorised the training set at 98% but held out at 36%).
    # C≈0.02 was the validation sweet spot in a hold-out sweep.
    print(f"training logistic regression on {len(Xs)} × {FEATURES} → {K} classes …")
    clf = LogisticRegression(max_iter=2000, C=0.02, n_jobs=-1)
    clf.fit(Xs, y)
    train_acc = clf.score(Xs, y)
    print(f"training accuracy: {train_acc * 100:.1f}%")

    # sklearn gives full per-class weights (K × 768) over the *standardised*
    # features. Fold the standardisation back so the weights act on raw features:
    #   w·(x-mu)/sigma + b  =  (w/sigma)·x + (b - Σ w·mu/sigma)
    coef = clf.coef_ / sigma                                  # (K,768)
    intercept = clf.intercept_ - (clf.coef_ * mu / sigma).sum(axis=1)
    if coef.shape[0] == 1:                                    # binary edge case
        coef = np.vstack([-coef, coef]); intercept = np.array([-intercept[0], intercept[0]])
    if coef.shape[0] == 1:                               # binary edge case
        coef = np.vstack([-coef, coef]); intercept = np.array([-intercept[0], intercept[0]])
    # CoreML's glmClassifier uses reference-class encoding: K-1 weight rows, one
    # per class AFTER the first, holding the log-odds relative to the FIRST class
    # (which is the reference, implicit score 0). This was verified empirically:
    # encoding relative to the last class put every prediction on the wrong
    # species. So rows map to classLabels[1..K-1] and classLabels[0] is the base.
    weights_ref = coef[1:] - coef[0]
    offset_ref = intercept[1:] - intercept[0]

    spec = ct.models.MLModel(str(template_path)).get_spec()
    glm = spec.pipelineClassifier.pipeline.models[1].glmClassifier

    del glm.weights[:]
    del glm.offset[:]
    for row in weights_ref:
        w = glm.weights.add()
        w.value.extend(float(v) for v in row)
    glm.offset.extend(float(v) for v in offset_ref)

    del glm.stringClassLabels.vector[:]
    glm.stringClassLabels.vector.extend(kept_labels)
    # The pipeline-level class label list must match too.
    cd = spec.description
    if cd.predictedFeatureName:
        for output in cd.output:
            if output.type.WhichOneof("Type") == "dictionaryType":
                pass  # dictionary key type is generic string→double, no per-class list

    ct.models.MLModel(spec).save(str(out_path))
    (out_path.with_suffix(".labels.txt")).write_text("\n".join(kept_labels) + "\n")
    print(f"wrote {out_path} — {K} species, dropped {len(dropped)}")


if __name__ == "__main__":
    main()
