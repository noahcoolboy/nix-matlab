#!/bin/sh
# Generate wrapper scripts in $out/bin for known user-facing MATLAB binaries.
set -eu

rawMatlab="$1"
outDir="$2"
runtimeShell="${3:-/bin/sh}"

# Only wrap actual user-facing CLI executables that may be present in the installation
for bName in \
  mex \
  mexext \
  mbuild \
  mcc \
  deploytool \
  worker \
  activate_matlab.sh \
  polyspace \
  polyspace-bug-finder \
  polyspace-code-prover
do
  bin="${rawMatlab}/bin/${bName}"
  if [ -f "$bin" ] && [ -x "$bin" ]; then
    cat > "${outDir}/bin/${bName}" << INNER_EOF
#!${runtimeShell}
export MAT_ENTRYPOINT="${bName}"
exec "${outDir}/bin/matlab" "\$@"
INNER_EOF
    chmod +x "${outDir}/bin/${bName}"
  fi
done
