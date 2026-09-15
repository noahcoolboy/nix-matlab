{ pkgs ? import <nixpkgs> {}
, system ? pkgs.stdenv.hostPlatform.system
, dataDir ? ../data
}:

let
  lib = pkgs.lib;

  md5 = import ./md5.nix;
  sign = import ./sign.nix;
  loader = import ./loader.nix { inherit pkgs lib; };
  builder = import ./builder.nix { inherit pkgs sign loader; };

  key = loader.loadKey dataDir;
  versionEntries = loader.loadVersions dataDir;

  # Build all packages lazily for all releases and availableUpdates
  packageList = lib.flatten (map (entry:
    let
      release = entry.release;
      updates = entry.availableUpdates or [];

      updateEntries = map (u: {
        name = "${release}.${u}";
        value =
          let
            # loadReleaseData resolves this update's database through import
            # from derivation. It must stay inside this thunk: hoisting it would
            # make evaluating any single package resolve every release.
            relData = loader.loadReleaseData {
              inherit dataDir system release;
              update = u;
            };
          in
          builder.mkMatlabRelease {
            inherit relData key;
          };
      }) updates;

      updateMap = builtins.listToAttrs updateEntries;
      defaultUpdate = entry.defaultUpdate or "";
      defaultPkg =
        if defaultUpdate != "" && updateMap ? "${release}.${defaultUpdate}" then
          updateMap."${release}.${defaultUpdate}"
        else
          (lib.last updateEntries).value;

      aliasEntry =
        if updateEntries != [] then [
          {
            name = release;
            value = defaultPkg;
          }
        ] else [];
    in
    updateEntries ++ aliasEntry
  ) versionEntries);

  buildPackages = builtins.listToAttrs packageList;

in {
  packages = buildPackages;
  lib = {
    inherit md5 sign loader builder;
    inherit (md5) md5Bytes md5Hex stringToBytes bytesToHex;
    inherit (sign) signUrl;
    inherit (loader) loadVersions loadKey dbPath resolveUpdate loadReleaseData
      toSnakeCase toKebabCase;
    inherit (builder) mkComponentDrv mkMatlabRelease;
  };
}
