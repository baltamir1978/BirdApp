#!/usr/bin/env python3
"""Derive the Iberian species list from BirdNET's own location/season meta-model.

Rather than hand-curating a list (or trusting a third-party checklist), we ask the
meta-model already bundled with the app which species it expects across a grid of
Iberian coordinates over a whole year. That guarantees the photo classifier we
train covers exactly what `LocationFilter` will later vouch for at run time.

The network is the one documented in BirdApp/LocationFilter.swift:

    [lat, lon, week] -> Fourier embedding(144)
                     -> 144-256-512-1024 MLP (ReLU)
                     -> 6522 logits -> sigmoid = per-species occurrence probability

Usage:
    python3 Tools/iberian_species.py [--threshold 0.01] [--out Tools/iberian_species.txt]
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
WEIGHTS = ROOT / "BirdApp" / "meta_weights.bin"
LABELS = ROOT.parent / "BirdNET_GLOBAL_6K_V2.4_Labels.txt"
NUM_CLASSES = 6522

# A coarse grid over mainland Iberia plus the Balearics. Points that fall in
# coastal water are harmless — the meta-model just reports seabirds there.
#
# The Canaries are deliberately out: their Macaronesian and African species
# (Cyanistes teneriffae, Pycnonotus barbatus, Passer simplex…) would spend model
# capacity on birds that never turn up on the mainland. Pass --canaries to
# include them.
#
# A plain lat/lon rectangle will not do: its southern and south-eastern corners
# sit in the Alborán Sea and off Algiers, close enough to Africa that the
# meta-model confidently returns North African birds there (Passer simplex at
# p=0.99, Pycnonotus barbatus at 0.99). So the grid is masked against a coarse
# outline of the peninsula and only land points are sampled.
IBERIA_OUTLINE = [                     # (lon, lat), clockwise from Galicia
    (-8.9, 43.8), (-4.5, 43.5), (-1.8, 43.4), (0.7, 42.9), (3.3, 42.4),
    (3.2, 41.9), (2.2, 41.2), (1.0, 40.7), (0.0, 39.6), (-0.5, 38.3), (-1.5, 37.4), (-2.2, 36.7),
    (-4.5, 36.7), (-5.6, 36.0), (-6.4, 36.8), (-7.5, 37.2), (-8.9, 37.0),
    (-9.5, 38.7), (-8.8, 41.0), (-9.3, 43.0),
]
BALEARICS = [(39.6, 2.9), (39.0, 1.4)]                     # Mallorca, Ibiza
CANARIES = [(28.3, -16.6), (28.1, -15.4)]


def on_land(lat: float, lon: float) -> bool:
    """Ray-casting point-in-polygon against the peninsula outline."""
    inside = False
    count = len(IBERIA_OUTLINE)
    for i in range(count):
        x1, y1 = IBERIA_OUTLINE[i]
        x2, y2 = IBERIA_OUTLINE[(i + 1) % count]
        if (y1 > lat) != (y2 > lat):
            crossing = x1 + (lat - y1) * (x2 - x1) / (y2 - y1)
            if lon < crossing:
                inside = not inside
    return inside


MAINLAND = [(lat, lon)
            for lat in np.arange(36.0, 44.01, 0.5)
            for lon in np.arange(-9.5, 3.51, 0.5)
            if on_land(float(lat), float(lon))]


def load_weights(path: Path):
    raw = path.read_bytes()
    if raw[:4] != b"BMET":
        raise SystemExit(f"{path} is not a BMET weights file")
    offset = 8
    floats = np.frombuffer(raw, dtype="<f4", offset=offset)

    cursor = 48                            # skip the unused leading freq block
    def take(count, shape=None):
        nonlocal cursor
        chunk = floats[cursor:cursor + count]
        cursor += count
        return chunk.reshape(shape) if shape else chunk

    W1 = take(256 * 144, (256, 144));    b1 = take(256)
    W2 = take(512 * 256, (512, 256));    b2 = take(512)
    W3 = take(1024 * 512, (1024, 512));  b3 = take(1024)
    W4 = take(NUM_CLASSES * 1024, (NUM_CLASSES, 1024)); b4 = take(NUM_CLASSES)
    return (W1, b1, W2, b2, W3, b3, W4, b4)


def embedding(lat: float, lon: float, week: int) -> np.ndarray:
    lat_n = (lat + 90) / 180
    lon_n = (lon + 180) / 360
    week_n = week / 48
    phase = np.arange(48) * (np.pi / 48)
    sqrt2 = np.sqrt(2.0)
    return np.concatenate([
        sqrt2 * np.sin(lat_n * 2 * np.pi + phase),
        sqrt2 * np.sin(lon_n * 2 * np.pi + phase),
        sqrt2 * np.sin(week_n * 2 * np.pi + phase),
    ]).astype("float32")


def probabilities(weights, features: np.ndarray) -> np.ndarray:
    W1, b1, W2, b2, W3, b3, W4, b4 = weights
    h = np.maximum(W1 @ features + b1, 0)
    h = np.maximum(W2 @ h + b2, 0)
    h = np.maximum(W3 @ h + b3, 0)
    return 1 / (1 + np.exp(-(W4 @ h + b4)))


def main() -> None:
    parser = argparse.ArgumentParser()
    # 0.01 is whoBIRD's "very likely" step; 0.001 its "possible" one.
    parser.add_argument("--threshold", type=float, default=0.01)
    parser.add_argument("--canaries", action="store_true", help="also cover the Canary Islands")
    parser.add_argument("--out", type=Path, default=ROOT / "Tools" / "iberian_species.txt")
    args = parser.parse_args()

    grid = MAINLAND + BALEARICS + (CANARIES if args.canaries else [])
    print(f"sampling {len(grid)} points × 48 weeks")

    weights = load_weights(WEIGHTS)
    labels = [line.strip() for line in LABELS.read_text().splitlines() if line.strip()]
    if len(labels) != NUM_CLASSES:
        raise SystemExit(f"expected {NUM_CLASSES} labels, found {len(labels)}")

    peak = np.zeros(NUM_CLASSES, dtype="float32")
    for lat, lon in grid:
        for week in range(1, 49):
            peak = np.maximum(peak, probabilities(weights, embedding(lat, lon, week)))

    keep = np.where(peak >= args.threshold)[0]
    keep = keep[np.argsort(-peak[keep])]

    lines = []
    for idx in keep:
        scientific, common = labels[idx].split("_", 1)
        lines.append(f"{idx}\t{scientific}\t{common}\t{peak[idx]:.4f}")
    args.out.write_text("\n".join(lines) + "\n")

    print(f"{len(keep)} species at p >= {args.threshold} -> {args.out}")
    for level in (0.05, 0.02, 0.01, 0.005, 0.001):
        print(f"  p >= {level:<6}: {(peak >= level).sum()} species")


if __name__ == "__main__":
    main()
