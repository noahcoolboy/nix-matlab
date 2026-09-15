#!/usr/bin/env python3
"""Point MATLAB's launcher at the FHS environment's library directories.

``bin/.matlab7rc.sh`` is where MATLAB expects a distribution to declare the
system library directories that belong on ``LD_LIBRARY_PATH``. It ships with
``LDPATH_SUFFIX=''`` — once per supported architecture block — for the packager
to fill in. Inside the FHS environment the libraries live under /lib, /usr/lib
and friends, so substitute those in at build time.
"""

import argparse
import os
import sys

PLACEHOLDER = "LDPATH_SUFFIX=''"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("matlabroot", help="root of the unpacked MATLAB tree")
    parser.add_argument(
        "--ldpath-suffix",
        required=True,
        help="colon-separated library directories to assign to LDPATH_SUFFIX",
    )
    args = parser.parse_args()

    rc_path = os.path.join(args.matlabroot, "bin", ".matlab7rc.sh")
    if not os.path.exists(rc_path):
        # Not every product selection ships the launcher.
        print(f"{rc_path}: not present, nothing to configure", file=sys.stderr)
        return 0

    # The file arrives read-only from the component zip, and MATLAB's launcher
    # sources it, so make it writable-and-executable before rewriting it.
    os.chmod(rc_path, 0o755)

    with open(rc_path) as f:
        content = f.read()

    count = content.count(PLACEHOLDER)
    if count == 0:
        # Failing here beats shipping an install whose libraries silently do not
        # resolve at runtime.
        print(
            f"{rc_path}: found no {PLACEHOLDER} to fill in; the file's format "
            f"has changed and this script needs updating",
            file=sys.stderr,
        )
        return 1

    content = content.replace(
        PLACEHOLDER, f"LDPATH_SUFFIX='{args.ldpath_suffix}'"
    )
    with open(rc_path, "w") as f:
        f.write(content)

    print(f"{rc_path}: set LDPATH_SUFFIX in {count} arch block(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
