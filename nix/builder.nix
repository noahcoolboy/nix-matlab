{ pkgs, sign ? import ./sign.nix }:

let
  lib = pkgs.lib;
  lndirPkg = pkgs.lndir or pkgs.xorg.lndir;

  # Build an individual component derivation
  mkComponentDrv = { comp, key, release, update, exp ? 2147483647 }:
    let
      # Sanitize component name for Nix derivation name
      safeName = builtins.replaceStrings
        [ "/" "_" "." "@" "+" ":" " " ]
        [ "-" "-" "-" "-" "-" "-" "-" ]
        comp.fn;

      signedUrl = sign.signUrl {
        inherit key exp;
        url = comp.url;
      };

      src = (pkgs.fetchurl {
        url = signedUrl;
        sha256 = comp.sha256;
      }).overrideAttrs (_: {
        preferLocalBuild = true;
        allowSubstitutes = false;
      });
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "matlab-comp-${safeName}";
      version = comp.ver;

      inherit src;

      preferLocalBuild = true;
      allowSubstitutes = false;

      nativeBuildInputs = [ pkgs.unzip ];

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

          # Instantiate derivations ONLY for selected components
          selectedDrvs = map (c: mkComponentDrv {
            comp = c;
            inherit key release update exp;
          }) uniqueSelectedComps;

          # Top-level derivation assembling the collection of component overlays
          matlabDrv = pkgs.stdenvNoCC.mkDerivation {
            pname = "matlab";
            version = "${release}.${update}";

            preferLocalBuild = true;
            allowSubstitutes = false;

            components = selectedDrvs;

            nativeBuildInputs = [ lndirPkg ];

            phases = [ "installPhase" ];

            installPhase = ''
              mkdir -p $out
              for comp in $components; do
                if [ -d "$comp" ]; then
                  ${lndirPkg}/bin/lndir -silent "$comp" "$out"
                fi
              done
            '';

            passthru = {
              inherit release update withDocs selectedDrvs;
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
        in
        matlabDrv;

      makeMatlabOverridable = lib.makeOverridable mkMatlabBase;

      defaultPkg = makeMatlabOverridable {
        withDocs = true;
        products = ps: [ ps.matlab ];
      };

    in
    defaultPkg;

in {
  inherit mkComponentDrv mkMatlabRelease;
}
