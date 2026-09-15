"""Refresh the component databases under data/.

For every release+update advertised in versions.json this fetches the update's
``dws.zip`` product manifest, records its products and components in
``data/<release>.<update>.sqlite``, and hashes as many not-yet-hashed components
as the quota allows.

Hashing is the slow part -- one HTTPS request per component, ~21k per update --
so it is budgeted rather than run to completion. Metadata is always refreshed;
hashes accumulate across runs, and a component keeps its hash forever because
the filename it is served under is specific to one update.

Usage:
    python3 scripts/main.py                    # default quota, all releases
    python3 scripts/main.py --quota 0          # metadata only, no hashing
    python3 scripts/main.py --quota inf        # hash everything still missing
    python3 scripts/main.py --release R2026a   # restrict to one release
"""

import argparse
import io
import json
import math
import sys
import xml.etree.ElementTree as ET
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests

import db as store
from key import get_key
from utils import DATA_DIR, form_path, hash as hash_url, sign
from versions import get_versions

HEADERS = {
    "User-Agent": "nix-matlab/1.0 (+https://github.com/noahcoolboy/nix-matlab)",
    "Accept-Encoding": "identity",
}

DEFAULT_URL_BASE = "https://esd.mathworks.com"

# Which manifest roots carry component references, and where those references
# sit. componentData lists them directly; the productData variants nest them one
# level down under <dependsOn>.
DIRECT_ROOTS = {"componentData"}
NESTED_ROOTS = {"productData", "productAdditionalComps", "productOptionalComps"}


def text_of(elem, tag, default=""):
    child = elem.find(tag)
    return child.text if child is not None and child.text else default


def components_in(root):
    if root.tag in DIRECT_ROOTS:
        return root.findall("component")
    if root.tag in NESTED_ROOTS:
        return [c for d in root.findall("dependsOn") for c in d.findall("component")]
    return []


def platform_of(name: str) -> str | None:
    """Platform a manifest entry belongs to, from its path inside dws.zip.

    Entries are named e.g. ``common/productdata_Foo252_common.xml`` or
    ``glnxa64/productdata_Foo252_glnxa64.xml``. Anything outside the known
    platform directories (the doc_ja/doc_ko/doc_zh trees, for instance) has no
    components Nix can install and is skipped.
    """
    head = name.split("/", 1)[0]
    return head if head in store.PLATFORMS else None


def fetch_manifest(key, entry, release: str, update: str) -> zipfile.ZipFile:
    url = form_path(entry["urlBase"], release, "Release", update)
    signed = sign(key, url, ttl=entry["urlSigning"]["ttlSeconds"])
    response = requests.get(signed, headers=HEADERS)
    response.raise_for_status()
    return zipfile.ZipFile(io.BytesIO(response.content))


def record_manifest(db, dws: zipfile.ZipFile) -> None:
    """Write every product and component in one dws.zip into the database."""
    for name in dws.namelist():
        if not name.endswith(".xml"):
            continue
        platform = platform_of(name)
        if platform is None:
            continue

        root = ET.parse(dws.open(name)).getroot()
        components = components_in(root)
        if not components:
            continue

        base_name = Path(name).stem
        prefix, suffix = "productdata_", f"_{platform}"
        if base_name.startswith(prefix) and base_name.endswith(suffix):
            base_name = base_name[len(prefix):-len(suffix)]

        product_id = store.upsert_product(
            db,
            base_name,
            text_of(root, "productName"),
            text_of(root, "productBaseCode"),
            text_of(root, "productVersion"),
        )

        for component in components:
            file_name = text_of(component, "componentFileName")
            if not file_name:
                continue
            component_id = store.upsert_component(
                db,
                file_name,
                platform,
                text_of(component, "doc", "0") == "1",
                text_of(component, "name"),
                text_of(component, "version"),
            )
            store.link(db, product_id, component_id)


def fill_hashes(db, key, entry, release: str, update: str, budget: int, workers: int) -> int:
    """Hash up to ``budget`` of this update's unhashed components."""
    if budget <= 0:
        return 0
    pending = store.missing_hashes(db, None if budget == math.inf else budget)
    if not pending:
        return 0

    ttl = entry["urlSigning"]["ttlSeconds"]

    def digest(file_name):
        url = form_path(entry["urlBase"], release, "Release", update,
                        "licensed_software", file_name)
        return file_name, hash_url(sign(key, url, ttl=ttl), headers=HEADERS)

    done = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for file_name, sha256 in pool.map(digest, pending):
            print(f"{release}.{update} {file_name} {sha256}")
            store.set_hash(db, file_name, sha256)
            done += 1
            # Commit periodically so an interrupted run keeps its progress.
            if done % 50 == 0:
                db.commit()
    db.commit()
    return done


def updates_of(entry) -> list[str]:
    """Available updates, default first.

    ``.#<release>`` aliases the default update, so spending the quota there
    first is what keeps the default package buildable.
    """
    updates = list(reversed(entry["availableUpdates"]))
    default = entry.get("defaultUpdate")
    if default and default in updates:
        updates.remove(default)
        updates.insert(0, default)
    return updates


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--quota", default="5000",
                        help="max components to hash this run, or 'inf' (default: 5000)")
    parser.add_argument("--workers", type=int, default=8,
                        help="concurrent hashing threads (default: 8)")
    parser.add_argument("--release", action="append", metavar="RELEASE",
                        help="only process this release; repeatable")
    parser.add_argument("--no-metadata", action="store_true",
                        help="skip the dws.zip refresh and only fill in hashes")
    args = parser.parse_args(argv)
    args.quota = math.inf if args.quota == "inf" else int(args.quota)
    return args


def main(argv=None) -> int:
    args = parse_args(argv)

    key = get_key()
    versions = get_versions()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "key.txt").write_text(key.decode("utf-8"), encoding="utf-8")
    (DATA_DIR / "versions.json").write_text(json.dumps(versions, indent=4), encoding="utf-8")

    quota = args.quota
    for entry in versions:
        if not entry.get("availableUpdates"):
            continue
        release = entry["release"]
        if args.release and release not in args.release:
            continue
        entry.setdefault("urlBase", DEFAULT_URL_BASE)

        for update in updates_of(entry):
            db = store.connect(release, update, entry["urlBase"])
            try:
                if not args.no_metadata:
                    record_manifest(db, fetch_manifest(key, entry, release, update))
                    db.commit()
                hashed = fill_hashes(db, key, entry, release, update, quota, args.workers)
                quota -= hashed
                remaining = len(store.missing_hashes(db))
                print(f"{release}.{update}: +{hashed} hashes, {remaining} still missing")
            finally:
                db.close()
            if quota <= 0:
                print(f"quota exhausted; {release}.{update} was the last update touched")
                return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
