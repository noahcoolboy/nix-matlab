{ pkgs ? import <nixpkgs> { inherit system; }
, system ? pkgs.stdenv.hostPlatform.system
, dataDir ? ../data
}:

let
  lib = pkgs.lib;

  md5 = import ./md5.nix;
  sign = import ./sign.nix;
  loader = import ./loader.nix { inherit lib; };
  builder = import ./builder.nix { inherit pkgs sign; };

  key = loader.loadKey dataDir;
  hashes = loader.loadHashes dataDir;
  versionEntries = loader.loadVersions dataDir;

  # Build all packages lazily for all releases and availableUpdates
  packageList = lib.flatten (map (entry:
    let
      release = entry.release;
      updates = entry.availableUpdates or [];
      urlBase = entry.urlBase or "https://esd.mathworks.com";
      lastUpdate =
        if updates != [] then
          builtins.elemAt updates ((builtins.length updates) - 1)
        else
          "";

      updateEntries = map (u: {
        name = "${release}.${u}";
        value =
          let
            relData = loader.loadReleaseData {
              inherit dataDir system release urlBase hashes;
              update = u;
            };
          in
          builder.mkMatlabRelease {
            inherit relData key;
          };
      }) updates;

      aliasEntry =
        if lastUpdate != "" then [
          {
            name = "${release}";
            value =
              let
                relData = loader.loadReleaseData {
                  inherit dataDir system release urlBase hashes;
                  update = lastUpdate;
                };
              in
              builder.mkMatlabRelease {
                inherit relData key;
              };
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
    inherit (loader) loadVersions loadKey loadHashes loadReleaseData toSnakeCase toKebabCase;
    inherit (builder) mkComponentDrv mkMatlabRelease;
  };
}
