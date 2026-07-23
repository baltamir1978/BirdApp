#!/usr/bin/env python3
"""Count how many usable training photos iNaturalist has per Iberian species.

Usable = research-grade observation whose photo carries a Creative Commons
licence (the "all rights reserved" ones must not go into a training set).

Two numbers per species: Iberia (Spain + Portugal) and worldwide. A blackbird is
a blackbird in Germany too, so worldwide is the fallback pool for species that
are scarce here — but Iberian photos come first, since local subspecies, plumage
and habitat are what the user will actually be photographing.

Writes a TSV so `inat_download.py` knows where to get each species' quota.

Usage:  python3 Tools/inat_census.py [--limit N]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPECIES = ROOT / "Tools" / "iberian_species.txt"
OUT = ROOT / "Tools" / "inat_census.tsv"

API = "https://api.inaturalist.org/v1/observations"
IBERIA = "6774,7122"                       # Spain, Portugal
CC = "cc0,cc-by,cc-by-nc,cc-by-sa"
# iNaturalist asks for <=60 requests/minute sustained; stay well under.
DELAY = 1.1
UA = "BirdApp/1.0 (training-set census; contact via github.com/baltamir1978/BirdApp)"


def count(taxon_name: str, place: str | None) -> int:
    params = {
        "taxon_name": taxon_name,
        "quality_grade": "research",
        "photo_license": CC,
        "per_page": 0,
    }
    if place:
        params["place_id"] = place
    url = f"{API}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)["total_results"]
        except Exception as error:              # rate limit, hiccup, timeout
            if attempt == 3:
                print(f"  ! {taxon_name}: {error}", file=sys.stderr)
                return -1
            time.sleep(2 ** attempt * 2)
    return -1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0, help="only the first N species")
    args = parser.parse_args()

    rows = [line.split("\t") for line in SPECIES.read_text().splitlines() if line.strip()]
    if args.limit:
        rows = rows[:args.limit]

    with OUT.open("w") as handle:
        handle.write("index\tscientific\tcommon\tprob\tiberia\tworld\n")
        for position, (index, scientific, common, prob) in enumerate(rows, 1):
            iberian = count(scientific, IBERIA)
            time.sleep(DELAY)
            # Only spend a second request when the local pool looks thin.
            worldwide = iberian
            if 0 <= iberian < 400:
                worldwide = count(scientific, None)
                time.sleep(DELAY)
            handle.write(f"{index}\t{scientific}\t{common}\t{prob}\t{iberian}\t{worldwide}\n")
            handle.flush()
            print(f"[{position}/{len(rows)}] {scientific}: {iberian} iberia / {worldwide} world",
                  flush=True)

    print(f"\nwrote {OUT}")


if __name__ == "__main__":
    main()
