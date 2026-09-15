"""SQLite storage for MATLAB product/component metadata.

One database per release+update, at ``data/<release>.<update>.sqlite``.

Components are *not* shared across updates. MathWorks repacks every component
for every update, so the same ``componentFileName`` served under
``.../Release/0/...`` and ``.../Release/1/...`` has different bytes: measured
over all known updates, 258442 (fileName, sha256) rows collapse to 258412
distinct pairs, a dedup factor of 1.00. Splitting per update instead keeps a
fetch run from rewriting databases it did not touch, and lets Nix resolve one
update without reading the rest.

Deduplication that does pay is *within* an update, across products: ~74k
(product, component) references collapse to ~21.5k distinct components, which
is what ``productComponents`` is for.
"""

import sqlite3
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

PLATFORMS = ("common", "glnxa64", "maci64", "maca64", "win64")

# ``url`` is deliberately absent from ``components``: it is always
# f"{urlBase}/{release}/Release/{update}/licensed_software/components/complete/{fileName}"
# and is rebuilt from ``meta`` when the tree is resolved.
#
# Secondary indexes are also deliberately absent. Resolution only ever walks
# products -> productComponents -> components, which the primary keys already
# cover, and each extra index costs ~0.6 MiB per update.
SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(
    k TEXT PRIMARY KEY,
    v TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS products(
    id       INTEGER PRIMARY KEY,
    baseName TEXT NOT NULL UNIQUE,
    name     TEXT NOT NULL,
    baseCode TEXT NOT NULL,
    version  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS components(
    id       INTEGER PRIMARY KEY,
    fileName TEXT NOT NULL UNIQUE,
    platform TEXT NOT NULL,
    doc      INTEGER NOT NULL,
    name     TEXT,
    version  TEXT,
    hash     BLOB
);

CREATE TABLE IF NOT EXISTS productComponents(
    productId   INTEGER NOT NULL REFERENCES products(id),
    componentId INTEGER NOT NULL REFERENCES components(id),
    PRIMARY KEY(productId, componentId)
) WITHOUT ROWID;
"""


def db_path(release: str, update: str) -> Path:
    return DATA_DIR / f"{release}.{update}.sqlite"


def connect(release: str, update: str, url_base: str | None = None) -> sqlite3.Connection:
    """Open (creating if needed) the database for one release+update."""
    path = db_path(release, update)
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript(SCHEMA)
    if url_base is not None:
        db.executemany(
            "INSERT INTO meta(k, v) VALUES(?, ?) "
            "ON CONFLICT(k) DO UPDATE SET v = excluded.v WHERE meta.v IS NOT excluded.v",
            [("release", release), ("update", update), ("urlBase", url_base)],
        )
    return db


def upsert_product(db, base_name: str, name: str, base_code: str, version: str) -> int:
    """Insert or refresh one product, returning its id.

    A product appears once per platform inside dws.zip and the entries are
    processed in whatever order the zip lists them, so an update must never
    replace a populated field with a blank one -- hence the coalesce/nullif.
    An empty column therefore means "no manifest supplied this"; substituting a
    default is left to nix/scripts/resolve.py, which is the only reader.

    The WHERE guard makes a re-run that changes nothing write nothing: SQLite
    files are binary, so git cannot delta them, and a no-op UPDATE would still
    dirty pages and put a fresh multi-megabyte blob in every commit.
    """
    db.execute(
        "INSERT INTO products(baseName, name, baseCode, version) VALUES(?, ?, ?, ?) "
        "ON CONFLICT(baseName) DO UPDATE SET "
        "  name     = coalesce(nullif(excluded.name, ''),     products.name), "
        "  baseCode = coalesce(nullif(excluded.baseCode, ''), products.baseCode), "
        "  version  = coalesce(nullif(excluded.version, ''),  products.version) "
        "WHERE products.name     IS NOT coalesce(nullif(excluded.name, ''),     products.name) "
        "   OR products.baseCode IS NOT coalesce(nullif(excluded.baseCode, ''), products.baseCode) "
        "   OR products.version  IS NOT coalesce(nullif(excluded.version, ''),  products.version)",
        (base_name, name, base_code, version),
    )
    return db.execute("SELECT id FROM products WHERE baseName = ?", (base_name,)).fetchone()[0]


def upsert_component(db, file_name: str, platform: str, doc: bool, name: str, version: str) -> int:
    """Insert or refresh one component, returning its id.

    ``hash`` is left untouched: it is filled in separately by the fetcher and
    must survive a metadata refresh. As with products, blanks never overwrite
    real values and an upsert that changes nothing writes nothing.
    """
    db.execute(
        "INSERT INTO components(fileName, platform, doc, name, version) VALUES(?, ?, ?, ?, ?) "
        "ON CONFLICT(fileName) DO UPDATE SET "
        "  platform = excluded.platform, "
        "  doc      = excluded.doc, "
        "  name     = coalesce(nullif(excluded.name, ''),    components.name), "
        "  version  = coalesce(nullif(excluded.version, ''), components.version) "
        "WHERE components.platform IS NOT excluded.platform "
        "   OR components.doc      IS NOT excluded.doc "
        "   OR components.name     IS NOT coalesce(nullif(excluded.name, ''),    components.name) "
        "   OR components.version  IS NOT coalesce(nullif(excluded.version, ''), components.version)",
        (file_name, platform, 1 if doc else 0, name, version),
    )
    return db.execute("SELECT id FROM components WHERE fileName = ?", (file_name,)).fetchone()[0]


def link(db, product_id: int, component_id: int) -> None:
    db.execute(
        "INSERT OR IGNORE INTO productComponents(productId, componentId) VALUES(?, ?)",
        (product_id, component_id),
    )


def missing_hashes(db, limit: int | None = None) -> list[str]:
    """Component filenames that still need to be hashed, oldest id first."""
    sql = "SELECT fileName FROM components WHERE hash IS NULL ORDER BY id"
    if limit is not None:
        sql += f" LIMIT {int(limit)}"
    return [row[0] for row in db.execute(sql)]


def set_hash(db, file_name: str, sha256_hex: str) -> None:
    """Record a component's digest, writing nothing if it already matches."""
    digest = bytes.fromhex(sha256_hex)
    db.execute(
        "UPDATE components SET hash = ? WHERE fileName = ? AND hash IS NOT ?",
        (digest, file_name, digest),
    )
