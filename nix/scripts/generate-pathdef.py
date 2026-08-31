#!/usr/bin/env python3
"""Generate ``toolbox/local/pathdef.m``, MATLAB's default search path.

A real MATLAB installer builds this file by concatenating the ``.phl`` path
fragments that each installed component drops into ``toolbox/local/path``.
Assembling components straight from their zips skips that step, so do it here:
read the fragments, keep the directories that actually exist, and splice them
into the placeholder in ``toolbox/local/template/pathdef.m``.

Order matters — MATLAB resolves shadowed function names by search-path order,
so core toolboxes have to come before the rest.
"""

import argparse
import glob
import os
import sys

MARKER = "'<PLEASE FILL IN ONE DIRECTORY PER LINE>:',..."

# Lower sorts earlier on the search path.
PRIORITIES = (
    "toolbox/matlab/",
    "toolbox/local",
    "toolbox/simulink/",
    "toolbox/stateflow/",
    "toolbox/rtw/",
)


def sort_key(path: str) -> tuple[int, str]:
    for rank, prefix in enumerate(PRIORITIES):
        if path.startswith(prefix):
            return (rank, path)
    return (len(PRIORITIES), path)


def collect_path_entries(matlabroot: str) -> list[str]:
    """Return the existing directories listed across every .phl fragment."""
    fragments = glob.glob(os.path.join(matlabroot, "toolbox/local/path/*.phl"))
    fragments += glob.glob(
        os.path.join(matlabroot, "derived/share/path/**/*.phl"), recursive=True
    )

    entries: list[str] = []
    seen: set[str] = set()
    for fragment in sorted(fragments):
        with open(fragment) as f:
            for line in f:
                entry = line.strip()
                if not entry or entry in seen:
                    continue
                if not os.path.isdir(os.path.join(matlabroot, entry)):
                    # Fragments list paths for components that may not be
                    # part of this product selection.
                    continue
                seen.add(entry)
                entries.append(entry)
    return sorted(entries, key=sort_key)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("matlabroot", help="root of the unpacked MATLAB tree")
    args = parser.parse_args()

    template = os.path.join(args.matlabroot, "toolbox/local/template/pathdef.m")
    if not os.path.exists(template):
        print(f"{template}: not present, nothing to generate", file=sys.stderr)
        return 0

    with open(template) as f:
        content = f.read()

    if MARKER not in content:
        print(
            f"{template}: placeholder not found; the template's format has "
            f"changed and this script needs updating",
            file=sys.stderr,
        )
        return 1

    entries = collect_path_entries(args.matlabroot)
    if not entries:
        print(f"{args.matlabroot}: no .phl path fragments found", file=sys.stderr)
        return 1

    content = content.replace(
        MARKER,
        "\n".join(f"    matlabroot,'/{entry}:', ..." for entry in entries),
    )

    output = os.path.join(args.matlabroot, "toolbox/local/pathdef.m")
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "w") as f:
        f.write(content)

    print(f"{output}: wrote {len(entries)} path entries", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
