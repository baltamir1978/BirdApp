#!/usr/bin/env python3
"""Build the Iberian training set from Creative Commons iNaturalist photos.

Layout is what Create ML expects — one directory per class:

    dataset/
      Turdus_merula/1234.jpg …
      Sturnus_unicolor/…
      attribution.tsv        (photo id, species, licence, photographer)

Rules that matter for data quality:
  * research-grade observations only (community-verified identification);
  * Creative Commons photos only — "all rights reserved" ones stay out;
  * at most ONE photo per observation, so a burst of the same individual in the
    same pose cannot dominate a class;
  * Iberian photos first, topped up worldwide for species that are scarce here.

The run is resumable: existing files are skipped, so it can be interrupted.

Usage:
    python3 Tools/inat_download.py --per-species 250 [--species-file …] [--out …]
"""

from __future__ import annotations

import argparse
import json
import queue
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = "https://api.inaturalist.org/v1/observations"
IBERIA = "6774,7122"                       # Spain, Portugal
CC = "cc0,cc-by,cc-by-nc,cc-by-sa"
PAGE = 200
API_DELAY = 1.1                            # iNaturalist asks for <=60 req/min
# Photos come from S3, which is happy to serve many at once — the 60 req/min
# courtesy limit applies to the API calls above, not to these. At 8 threads a
# full run took an estimated 13 hours; this brings it under three.
PHOTO_THREADS = 24
EDGE = 320                                 # stored long-side size, see `store`
UA = "BirdApp/1.0 (training set; contact via github.com/baltamir1978/BirdApp)"


def api_get(params: dict) -> dict | None:
    url = f"{API}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.load(response)
        except Exception as error:
            if attempt == 3:
                print(f"  ! api: {error}", file=sys.stderr)
                return None
            time.sleep(2 ** attempt * 2)
    return None


def gather(scientific: str, wanted: int) -> list[dict]:
    """Photo records for one species: Iberia first, then worldwide to top up."""
    seen: dict[str, dict] = {}

    for place in (IBERIA, None):
        page = 1
        while len(seen) < wanted:
            params = {
                "taxon_name": scientific,
                "quality_grade": "research",
                "photo_license": CC,
                "per_page": PAGE,
                "page": page,
                # Deliberately NOT order_by=votes. The most-favourited photos skew
                # towards the unusual and the spectacular — the first blackbird it
                # returned was a leucistic one — and a training set wants typical
                # birds. The default ordering is effectively neutral on appearance.
            }
            if place:
                params["place_id"] = place
            payload = api_get(params)
            time.sleep(API_DELAY)
            if not payload or not payload.get("results"):
                break

            for observation in payload["results"]:
                photos = observation.get("photos") or []
                if not photos:
                    continue
                # One photo per observation only.
                photo = photos[0]
                if not photo.get("license_code"):
                    continue
                key = str(photo["id"])
                if key in seen:
                    continue
                seen[key] = {
                    "id": key,
                    # square.jpg -> medium.jpg (about 500 px on the long side)
                    "url": photo["url"].replace("/square.", "/medium."),
                    "license": photo["license_code"],
                    "author": (photo.get("attribution") or "").replace("\t", " "),
                }
                if len(seen) >= wanted:
                    break

            if page * PAGE >= min(payload.get("total_results", 0), 10000):
                break
            page += 1

        if len(seen) >= wanted:
            break

    return list(seen.values())


def store(data: bytes, target: Path) -> None:
    """Save the photo shrunk to `EDGE` px on its long side.

    iNaturalist's "medium" is ~500 px and ~170 KB; at 390 species × 250 photos
    that would be 17 GB. Create ML's feature extractor works at 299×299, so
    anything above `EDGE` is discarded detail — this keeps the set around 3 GB
    without costing accuracy.
    """
    from io import BytesIO

    from PIL import Image

    image = Image.open(BytesIO(data))
    if image.mode != "RGB":
        image = image.convert("RGB")
    if max(image.size) > EDGE:
        scale = EDGE / max(image.size)
        image = image.resize((max(1, round(image.width * scale)),
                              max(1, round(image.height * scale))),
                             Image.LANCZOS)
    image.save(target, "JPEG", quality=88, optimize=True)


def fetch_photos(records: list[dict], folder: Path) -> int:
    """Download in parallel; returns how many new files landed."""
    folder.mkdir(parents=True, exist_ok=True)
    pending: queue.Queue = queue.Queue()
    for record in records:
        target = folder / f"{record['id']}.jpg"
        if not target.exists():
            pending.put((record, target))

    saved = threading.BoundedSemaphore(1)
    count = [0]

    def worker() -> None:
        while True:
            try:
                record, target = pending.get_nowait()
            except queue.Empty:
                return
            try:
                request = urllib.request.Request(record["url"], headers={"User-Agent": UA})
                with urllib.request.urlopen(request, timeout=45) as response:
                    data = response.read()
                if len(data) > 3000:              # skip truncated / placeholder images
                    store(data, target)
                    with saved:
                        count[0] += 1
            except Exception:
                pass                              # a missing photo is not worth failing over
            finally:
                pending.task_done()

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(PHOTO_THREADS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return count[0]


# Non-bird classes for the `__background__` bucket. AIY Birds V1 ships such a
# class and PhotoIdentifier already relies on it to answer "no bird here"; a
# Create ML classifier has no equivalent, so without this every photo of a chair
# or a flower would be confidently labelled some warbler.
BACKGROUND_TAXA = {
    "Plantae": 47126,
    "Insecta": 47158,
    "Mammalia": 40151,
    "Reptilia": 26036,
    "Amphibia": 20978,
    "Arachnida": 47119,
    "Fungi": 47170,
    "Mollusca": 47115,
}


def gather_background(per_taxon: int) -> list[dict]:
    """Photos of things that are emphatically not birds."""
    records: dict[str, dict] = {}
    for name, taxon_id in BACKGROUND_TAXA.items():
        page = 1
        collected = 0
        while collected < per_taxon:
            payload = api_get({
                "taxon_id": taxon_id,
                "quality_grade": "research",
                "photo_license": CC,
                "place_id": IBERIA,          # same landscapes the user photographs
                "per_page": PAGE,
                "page": page,
            })
            time.sleep(API_DELAY)
            if not payload or not payload.get("results"):
                break
            for observation in payload["results"]:
                photos = observation.get("photos") or []
                if not photos or not photos[0].get("license_code"):
                    continue
                key = str(photos[0]["id"])
                if key in records:
                    continue
                records[key] = {
                    "id": key,
                    "url": photos[0]["url"].replace("/square.", "/medium."),
                    "license": photos[0]["license_code"],
                    "author": (photos[0].get("attribution") or "").replace("\t", " "),
                }
                collected += 1
                if collected >= per_taxon:
                    break
            page += 1
        print(f"  background/{name}: {collected}", flush=True)
    return list(records.values())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--per-species", type=int, default=250)
    parser.add_argument("--background", type=int, default=60,
                        help="non-bird photos per taxon for the __background__ class")
    parser.add_argument("--min-photos", type=int, default=40,
                        help="skip species that cannot reach this many photos")
    parser.add_argument("--species-file", type=Path,
                        default=ROOT / "Tools" / "iberian_species_peninsular.txt")
    parser.add_argument("--out", type=Path, default=ROOT / "Tools" / "dataset")
    args = parser.parse_args()

    rows = [line.split("\t") for line in args.species_file.read_text().splitlines() if line.strip()]
    # A small --per-species (a trial run) must not make every species look starved.
    floor = min(args.min_photos, args.per_species)
    args.out.mkdir(parents=True, exist_ok=True)
    # Bookkeeping lives NEXT TO the dataset, never inside it: Create ML reads
    # `dataset/` as "one directory per class" and a stray file there is an error.
    attribution = (args.out.parent / f"{args.out.name}_attribution.tsv").open("a")

    totals = 0
    skipped = []
    for position, row in enumerate(rows, 1):
        scientific = row[1]
        folder = args.out / scientific.replace(" ", "_")
        existing = len(list(folder.glob("*.jpg"))) if folder.exists() else 0
        if existing >= args.per_species:
            print(f"[{position}/{len(rows)}] {scientific}: {existing} already there", flush=True)
            totals += existing
            continue

        records = gather(scientific, args.per_species)
        if len(records) < floor:
            print(f"[{position}/{len(rows)}] {scientific}: only {len(records)} photos — SKIPPED",
                  flush=True)
            skipped.append(f"{scientific}\t{len(records)}")
            continue

        added = fetch_photos(records, folder)
        for record in records:
            attribution.write(f"{record['id']}\t{scientific}\t{record['license']}\t{record['author']}\n")
        attribution.flush()

        have = len(list(folder.glob("*.jpg")))
        totals += have
        print(f"[{position}/{len(rows)}] {scientific}: +{added} → {have}", flush=True)

    if args.background:
        folder = args.out / "__background__"
        have = len(list(folder.glob("*.jpg"))) if folder.exists() else 0
        if have < args.background * len(BACKGROUND_TAXA) * 0.8:
            print("\nBackground class (non-birds):", flush=True)
            records = gather_background(args.background)
            added = fetch_photos(records, folder)
            for record in records:
                attribution.write(f"{record['id']}\t__background__\t{record['license']}\t{record['author']}\n")
            print(f"  __background__: +{added} → {len(list(folder.glob('*.jpg')))}", flush=True)
        else:
            print(f"\n__background__: {have} already there", flush=True)

    attribution.close()
    if skipped:
        (args.out.parent / f"{args.out.name}_skipped.tsv").write_text("\n".join(skipped) + "\n")
    print(f"\n{totals} photos across {len(rows) - len(skipped)} species in {args.out}")
    print(f"{len(skipped)} species skipped for lack of photos")


if __name__ == "__main__":
    main()
