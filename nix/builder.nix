{ pkgs
, sign ? import ./sign.nix
, loader ? import ./loader.nix { inherit (pkgs) lib; }
}:

let
  lib = pkgs.lib;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  matlabFhsPackages = p: import ./pkgs.nix { pkgs = p; };

  # Library directories inside the FHS environment. MATLAB needs these at build
  # time (baked into bin/.matlab7rc.sh) and again at run time (exported into the
  # FHS profile), so they are declared once here.
  fhsLibDirs = [
    "/lib"
    "/usr/lib"
    "/usr/lib64"
    "/run/opengl-driver/lib" # NixOS GPU drivers, for hardware OpenGL
  ];
  fhsLibPath = lib.concatStringsSep ":" fhsLibDirs;

  # Build an individual component fetch derivation
  mkComponentSrc = { comp, key, exp ? 2147483647 }:
    let
      safeName = loader.toKebabCase comp.fn;
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
      safeName = loader.toKebabCase comp.fn;
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
  wrapMatlabFhs = { rawMatlab, extraPkgs ? (p: [ ]) }:
    if isLinux then
      let
        fhs = pkgs.buildFHSEnv {
          name = "matlab";
          targetPkgs = p: (matlabFhsPackages p) ++ (extraPkgs p);
          profile = ''
            export LDPATH_SUFFIX="${fhsLibPath}"
            export LD_LIBRARY_PATH="${fhsLibPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
          runScript = "${./scripts/fhs-entrypoint.sh} ${rawMatlab}";
          extraInstallCommands = "${pkgs.runtimeShell} ${./scripts/wrap-binaries.sh} ${rawMatlab} $out ${pkgs.runtimeShell}";
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
      mkMatlabBase = { withDocs ? true, products ? (ps: [ ps.matlab ]), licenseMode ? "onlinelicensing", extraPkgs ? (p: [ ]) }:
        let
          # Evaluate user products function against product map
          selectedRaw = products relData.products;
          selectedList = lib.flatten (lib.toList selectedRaw);

          # Extract components from the selected products
          extractComps = item:
            if builtins.isAttrs item then
              if item ? components then (
                if withDocs then item.components
                else builtins.filter (c: !c.isDoc) item.components
              )
              else if item ? fn then [ item ]
              else []
            else [];

          allSelectedComps = lib.flatten (map extractComps selectedList);
          uniqueSelectedComps = loader.dedupComponents allSelectedComps;

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

          # $MATLABROOT/licenses is read-only in the store, so the licensing mode has
          # to be baked in. MATLAB searches $HOME/.matlab/<release>_licenses before
          # $MATLABROOT/licenses, so a user-supplied license file (or MLM_LICENSE_FILE)
          # still takes precedence over this default.
          licenseInfoFile =
            if licenseMode == null then null
            else pkgs.writeText "matlab-license-info.xml" ''
              <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
              <root>

                <ActivationEntry hostname="*" matlabroot="*" user="*">
                  <licmode>${licenseMode}</licmode>
                </ActivationEntry>

              </root>
            '';

          # Top-level raw derivation assembling the collection of component overlays directly
          rawMatlabDrv = pkgs.stdenvNoCC.mkDerivation {
            pname = "matlab-unwrapped";
            version = "${release}.${update}";

            preferLocalBuild = true;
            allowSubstitutes = false;

            inherit manifest;

            nativeBuildInputs = [ pkgs.python3 ];

            dontUnpack = true;
            dontFixup = true;
            dontPatchELF = true;
            dontStrip = true;

            installPhase = ''
              # Unpack every component (OPC .enc -> fsroot/*.zip -> files) in one
              # Python process, preserving per-file modes and symlinks.
              python3 ${./scripts/extract-components.py} "$manifest" "$out"

              # bin/.matlab7rc.sh and toolbox/local/pathdef.m are normally generated by
              # MathWorks' installer. Assembling components straight from their zips
              # skips that step, so run the equivalent here.
              python3 ${./scripts/configure-matlab7rc.py} "$out" \
                --ldpath-suffix ${lib.escapeShellArg fhsLibPath}
              python3 ${./scripts/generate-pathdef.py} "$out"

            '' + lib.optionalString (licenseMode != null) ''

              install -Dm444 ${licenseInfoFile} "$out/licenses/license_info.xml"
            '';

            meta = {
              mainProgram = "matlab";
              description = "MATLAB programming and numeric computing platform (unwrapped)";
            };

            passthru = {
              inherit release update withDocs licenseMode uniqueSelectedComps selectedSrcs manifest;
              productsMap = relData.products;
              uniqueProducts = relData.uniqueProducts;
              allProductList = relData.productList;

              # 3 pre-provided overrides (which can further be overridden)
              minimal = makeMatlabOverridable {
                withDocs = false;
                products = ps: [ ps.matlab ];
              };

              default = defaultPkg;

              full = makeMatlabOverridable {
                withDocs = true;
                products = ps: builtins.attrValues relData.uniqueProducts;
              };
            };
          };

          wrappedMatlab = wrapMatlabFhs {
            rawMatlab = rawMatlabDrv;
            inherit extraPkgs;
          };
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
