#!/usr/bin/env python3
"""Resolve one release+update's component tree out of SQLite into JSON for Nix.

Run inside a derivation and read back with ``builtins.fromJSON`` (import from
derivation). Doing the join here rather than in the Nix expression means Nix
reads one file per (release, update, platform) instead of walking ~840 JSON
files, and the string munging for product aliases happens in Python.

Usage: resolve.py <database> <platform> > out.json

The output must be byte-identical for a given database or Nix rebuilds
everything downstream, so every query is explicitly ordered and the JSON is
emitted with sorted keys.
"""

import json
import sqlite3
import sys

# Characters that separate words in product names, replaced wholesale when
# building the snake_case/kebab-case aliases. Kept in sync with the same list
# in nix/loader.nix.
SEP_CHARS = " -_./:()[],+@#$%^&*"


def _replace_seps(text: str, sep: str) -> str:
    return "".join(sep if c in SEP_CHARS else c for c in text.lower())


def aliases_for(product_name: str, base_name: str, base_code: str) -> list[str]:
    """Every attribute name a product can be selected by.

    Order matters only for reproducibility; duplicates and empties are dropped
    while preserving first appearance.
    """
    candidates = [product_name, base_name, base_code, base_code.lower()]
    for name in (product_name, base_name):
        candidates.append(_replace_seps(name, "_"))
        candidates.append(_replace_seps(name, "-"))
    return [a for a in dict.fromkeys(candidates) if a]


def resolve(db_path: str, platform: str) -> dict:
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)

    meta = dict(db.execute("SELECT k, v FROM meta"))
    release, update = meta["release"], meta["update"]
    url_prefix = (
        f"{meta['urlBase']}/{release}/Release/{update}"
        f"/licensed_software/components/complete/"
    )

    # Components are emitted per product with the URL prefix factored out; Nix
    # concatenates prefix + fn. Repeating the full URL on every one of ~35k
    # components would triple the size of this file for no added information.
    products = []
    for pid, base_name, name, base_code, version in db.execute(
        "SELECT id, baseName, name, baseCode, version FROM products ORDER BY baseName"
    ):
        components = [
            {
                "fn": fn,
                "isDoc": bool(doc),
                "name": comp_name or fn,
                "ver": comp_version or "",
                # A NULL hash means the component has not been fetched yet.
                # Emitting "" keeps the previous behaviour: the component stays
                # visible in the product tree and only fails if actually built.
                "sha256": comp_hash.hex() if comp_hash else "",
            }
            for fn, doc, comp_name, comp_version, comp_hash in db.execute(
                "SELECT c.fileName, c.doc, c.name, c.version, c.hash "
                "FROM productComponents pc "
                "JOIN components c ON c.id = pc.componentId "
                "WHERE pc.productId = ? AND c.platform IN ('common', ?) "
                "ORDER BY c.fileName",
                (pid, platform),
            )
        ]
        # An empty name means no manifest carried the field; fall back to the
        # filename stem the product is known by, as components do with fn.
        name = name or base_name
        products.append(
            {
                "name": name,
                "baseName": base_name,
                "code": base_code,
                "version": version,
                "aliases": aliases_for(name, base_name, base_code),
                "components": components,
            }
        )

    return {
        "release": release,
        "update": update,
        "platform": platform,
        "urlPrefix": url_prefix,
        "productList": products,
    }


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <database> <platform>")
    json.dump(resolve(sys.argv[1], sys.argv[2]), sys.stdout, sort_keys=True, separators=(",", ":"))


if __name__ == "__main__":
    main()
