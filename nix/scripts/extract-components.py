#!/usr/bin/env python3
"""Unpack MATLAB components into MATLABROOT, in a single process.

Each component is an OPC package (``.enc``) whose ``fsroot/<name>.zip`` payload
holds the real files, laid out relative to MATLABROOT. This replaces the shell
``unzip`` loop: one Python process instead of ~2-3 subprocess spawns per
component, and the payload zip is read straight from the OPC in memory rather
than written to a temp dir and unzipped again.

``zipfile`` does NOT do two things Info-ZIP ``unzip`` did for free, so we do them
explicitly:

  * per-file Unix permissions — MATLAB ships ~0o444 data files and ~0o555
    executables; the mode lives in the high 16 bits of ``external_attr``.
  * symlinks — versioned libraries (``libX11.so.6 -> libX11.so.6.4.0``) are
    stored as ``S_IFLNK`` entries whose "contents" are the link target.
    ``zipfile.extract`` would write those as regular text files and break the
    dynamic linker.

Later components overwrite earlier ones (matching ``unzip -o``); the unlink
before write also lets us replace read-only (0o444) files. Directories are left
writable during the build so subsequent components can add to them — Nix seals
the whole store read-only afterwards.
"""

import io
import os
import shutil
import stat
import sys
import zipfile


def _safe_dest(out: str, name: str) -> str:
    dest = os.path.normpath(os.path.join(out, name))
    if dest != out and not dest.startswith(out + os.sep):
        raise ValueError(f"refusing to write outside MATLABROOT: {name!r}")
    return dest


def extract_inner(inner: zipfile.ZipFile, out: str) -> int:
    count = 0
    for info in inner.infolist():
        perm = (info.external_attr >> 16) & 0o7777
        ftype = (info.external_attr >> 16) & 0o170000
        dest = _safe_dest(out, info.filename)

        if info.is_dir():
            # Keep dirs writable for later components; the store is sealed later.
            os.makedirs(dest, exist_ok=True)
            continue

        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.lexists(dest):
            os.remove(dest)  # last-writer-wins; also lets us overwrite 0o444 files

        if stat.S_ISLNK(ftype):
            target = inner.read(info).decode("utf-8", "surrogateescape")
            os.symlink(target, dest)
        else:
            with inner.open(info) as src, open(dest, "wb") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
            os.chmod(dest, perm or 0o444)
        count += 1
    return count


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract-components.py <manifest> <matlabroot>", file=sys.stderr)
        return 2
    manifest, out = sys.argv[1], os.path.normpath(sys.argv[2])
    os.makedirs(out, exist_ok=True)

    components = files = 0
    with open(manifest) as mf:
        for line in mf:
            src = line.strip()
            if not src:
                continue
            components += 1
            with zipfile.ZipFile(src) as opc:
                payloads = [
                    n for n in opc.namelist()
                    if n.startswith("fsroot/") and n.endswith(".zip")
                ]
                for payload in payloads:
                    with zipfile.ZipFile(io.BytesIO(opc.read(payload))) as inner:
                        files += extract_inner(inner, out)

    print(f"extracted {files} files from {components} components", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
