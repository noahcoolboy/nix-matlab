{ pkgs, sign ? import ./sign.nix }:

let
  lib = pkgs.lib;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  matlabFhsPackages = p: import ./pkgs.nix { pkgs = p; };

  # Build an individual component fetch derivation
  mkComponentSrc = { comp, key, exp ? 2147483647 }:
    let
      safeName = builtins.replaceStrings
        [ "/" "_" "." "@" "+" ":" " " ]
        [ "-" "-" "-" "-" "-" "-" "-" ]
        comp.fn;
    in
    (pkgs.fetchurl {
      name = "matlab-src-${safeName}";
      url = sign.signUrl {
        inherit key exp;
        url = comp.url;
      };
      sha256 = comp.sha256;
    }).overrideAttrs (_: {
      preferLocalBuild = true;
      allowSubstitutes = false;
    });

  # Build an individual component derivation (standalone overlay)
  mkComponentDrv = { comp, key, release, update, exp ? 2147483647 }:
    let
      safeName = builtins.replaceStrings
        [ "/" "_" "." "@" "+" ":" " " ]
        [ "-" "-" "-" "-" "-" "-" "-" ]
        comp.fn;

      src = mkComponentSrc { inherit comp key exp; };
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "matlab-comp-${safeName}";
      version = comp.ver;

      inherit src;

      preferLocalBuild = true;
      allowSubstitutes = false;

      nativeBuildInputs = [ pkgs.unzip ];

      dontFixup = true;
      dontPatchELF = true;
      dontStrip = true;

      phases = [ "installPhase" ];

      installPhase = ''
        mkdir -p $out tmp
        unzip -q $src -d tmp
        if [ -d tmp/fsroot ]; then
          for z in tmp/fsroot/*.zip; do
            if [ -f "$z" ]; then
              unzip -q -o "$z" -d $out
            fi
          done
        fi
        rm -rf tmp
      '';

      passthru = {
        inherit comp;
      };
    };

  # Wrap an unpacked MATLAB derivation in an FHS environment on Linux
  wrapMatlabFhs = rawMatlab:
    if isLinux then
      let
        fhs = pkgs.buildFHSEnv {
          name = "matlab";
          targetPkgs = matlabFhsPackages;
          profile = ''
            export LDPATH_SUFFIX="/lib:/usr/lib:/usr/lib64:/run/opengl-driver/lib"
            export LD_LIBRARY_PATH="/lib:/usr/lib:/usr/lib64:/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
          runScript = "${rawMatlab}/bin/matlab";
          meta = {
            mainProgram = "matlab";
            description = "MATLAB programming and numeric computing platform";
            platforms = pkgs.lib.platforms.linux;
          };
          passthru = {
            unwrapped = rawMatlab;
          } // rawMatlab.passthru;
        };
      in
      fhs
    else
      rawMatlab;

  # Build MATLAB installation from release data
  mkMatlabRelease = { relData, key, exp ? 2147483647 }:
    let
      release = relData.release;
      update = relData.update;

      # Function to make a MATLAB installation derivation
      mkMatlabBase = { withDocs ? true, products ? (ps: [ ps.matlab ]) }:
        let
          # For each product, create a product representation
          makeProductEntry = prod:
            let
              filteredComps =
                if withDocs then prod.components
                else builtins.filter (c: !c.isDoc) prod.components;
            in {
              inherit (prod) name baseName code version aliases;
              components = prod.components;
              filteredComponents = filteredComps;
            };

          # Products map with aliases
          psMap =
            builtins.foldl' (acc: prod:
              let
                pEntry = makeProductEntry prod;
                aliasEntries = builtins.foldl' (aAcc: alias:
                  aAcc // { "${alias}" = pEntry; }
                ) {} prod.aliases;
              in
              acc // aliasEntries
            ) {} relData.productList;

          # Unique products map
          uniquePsMap =
            builtins.foldl' (acc: prod:
              acc // { "${prod.name}" = makeProductEntry prod; }
            ) {} relData.productList;

          # Evaluate user products function
          selectedRaw = products psMap;
          selectedList = lib.flatten (lib.toList selectedRaw);

          # Extract components from the selected products
          extractComps = item:
            if builtins.isAttrs item then
              if item ? filteredComponents then item.filteredComponents
              else if item ? components then (
                if withDocs then item.components
                else builtins.filter (c: !c.isDoc) item.components
              )
              else if item ? fn then [ item ]
              else []
            else [];

          allSelectedComps = lib.flatten (map extractComps selectedList);

          # Deduplicate components by filename
          uniqueSelectedComps =
            builtins.attrValues (
              builtins.foldl' (acc: c:
                if c.fn == "" then acc
                else acc // { "${c.fn}" = c; }
              ) {} allSelectedComps
            );

          # Download sources for all unique selected components
          selectedSrcs = map (c: mkComponentSrc {
            comp = c;
            inherit key exp;
          }) uniqueSelectedComps;

          # Write sources to a manifest file to avoid exceeding Linux MAX_ARG_STRLEN (128 KB)
          # when passing thousands of store paths as environment variables
          manifest = pkgs.writeText "matlab-sources-${release}.${update}.txt" (
            lib.concatStringsSep "\n" (map (s: "${s}") selectedSrcs)
          );

          # Top-level raw derivation assembling the collection of component overlays directly
          rawMatlabDrv = pkgs.stdenvNoCC.mkDerivation {
            pname = "matlab-unwrapped";
            version = "${release}.${update}";

            preferLocalBuild = true;
            allowSubstitutes = false;

            inherit manifest;

            nativeBuildInputs = [ pkgs.unzip pkgs.python3 ];

            dontUnpack = true;
            dontFixup = true;
            dontPatchELF = true;
            dontStrip = true;

            installPhase = ''
              mkdir -p $out tmp
              while IFS= read -r src; do
                if [ -n "$src" ]; then
                  unzip -q -o "$src" -d tmp
                  if [ -d tmp/fsroot ]; then
                    for z in tmp/fsroot/*.zip; do
                      if [ -f "$z" ]; then
                        unzip -q -o "$z" -d $out
                      fi
                    done
                    rm -rf tmp/fsroot
                  fi
                fi
              done < "$manifest"
              rm -rf tmp

              # Configure .matlab7rc.sh with FHS library directories
              python3 -c '
import os
rc_path = "'"$out"'/bin/.matlab7rc.sh"
if os.path.exists(rc_path):
    os.chmod(rc_path, 0o755)
    with open(rc_path) as f:
        c = f.read()
    c = c.replace("LDPATH_SUFFIX=\x27\x27", "LDPATH_SUFFIX=\x27/lib:/usr/lib:/usr/lib64:/run/opengl-driver/lib\x27")
    with open(rc_path, "w") as f:
        f.write(c)
'

              # Generate toolbox/local/pathdef.m from installed .phl files
              if [ -f "$out/toolbox/local/template/pathdef.m" ]; then
                mkdir -p "$out/toolbox/local"
                python3 -c '
import os, glob

matlabroot = "'"$out"'"
template_file = os.path.join(matlabroot, "toolbox/local/template/pathdef.m")
with open(template_file) as f:
    content = f.read()

phl_dir = os.path.join(matlabroot, "toolbox/local/path")
phl_files = glob.glob(os.path.join(phl_dir, "*.phl"))
alt_dir = os.path.join(matlabroot, "derived/share/path")
if os.path.exists(alt_dir):
    phl_files.extend(glob.glob(os.path.join(alt_dir, "**/*.phl"), recursive=True))

paths = []
seen = set()
for pf in phl_files:
    with open(pf) as f:
        for line in f:
            line = line.strip()
            if line and os.path.isdir(os.path.join(matlabroot, line)) and line not in seen:
                seen.add(line)
                paths.append(line)

def sort_key(p):
    if p.startswith("toolbox/matlab/"): return (0, p)
    if p.startswith("toolbox/local"): return (1, p)
    if p.startswith("toolbox/simulink/"): return (2, p)
    if p.startswith("toolbox/stateflow/"): return (3, p)
    if p.startswith("toolbox/rtw/"): return (4, p)
    return (5, p)

sorted_paths = sorted(paths, key=sort_key)
entries_str = "\n".join([f"    matlabroot,\x27/{p}:\x27, ..." for p in sorted_paths])

marker = "\x27<PLEASE FILL IN ONE DIRECTORY PER LINE>:\x27,..."
content = content.replace(marker, entries_str)

output_file = os.path.join(matlabroot, "toolbox/local/pathdef.m")
with open(output_file, "w") as f:
    f.write(content)
'
              fi

              if [ -d "$out/bin" ]; then
                chmod -R +x "$out/bin"
              fi
            '';

            meta = {
              mainProgram = "matlab";
              description = "MATLAB programming and numeric computing platform (unwrapped)";
            };

            passthru = {
              inherit release update withDocs uniqueSelectedComps selectedSrcs manifest;
              productsMap = psMap;
              uniqueProducts = uniquePsMap;
              allProductList = relData.productList;

              # 3 pre-provided overrides (which can further be overridden)
              minimal = makeMatlabOverridable {
                withDocs = false;
                products = ps: [ ps.matlab ];
              };

              default = makeMatlabOverridable {
                withDocs = true;
                products = ps: [ ps.matlab ];
              };

              full = makeMatlabOverridable {
                withDocs = true;
                products = ps: builtins.attrValues uniquePsMap;
              };
            };
          };

          wrappedMatlab = wrapMatlabFhs rawMatlabDrv;
        in
        wrappedMatlab;

      makeMatlabOverridable = lib.makeOverridable mkMatlabBase;

      defaultPkg = makeMatlabOverridable {
        withDocs = true;
        products = ps: [ ps.matlab ];
      };

    in
    defaultPkg;

in {
  inherit mkComponentSrc mkComponentDrv mkMatlabRelease wrapMatlabFhs matlabFhsPackages;
}
