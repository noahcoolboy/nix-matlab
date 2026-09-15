#!/bin/sh
# Entrypoint inside the FHS container. Dispatches to the binary specified
# by MAT_ENTRYPOINT (e.g. mex, mcc, deploytool), defaulting to matlab.
set -eu

rawMatlab="$1"
shift

binName="${MAT_ENTRYPOINT:-matlab}"
if [ -f "${rawMatlab}/bin/${binName}" ]; then
  exec "${rawMatlab}/bin/${binName}" "$@"
else
  exec "${rawMatlab}/bin/matlab" "$@"
fi
