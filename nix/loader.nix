{ lib ? import <nixpkgs> { } }:

let
  systemToPlatform = {
    "x86_64-linux" = "glnxa64";
    "aarch64-linux" = "glnxa64";
    "x86_64-darwin" = "maci64";
    "aarch64-darwin" = "maca64";
    "x86_64-windows" = "win64";
    "i686-windows" = "win64";
  };

  # Normalize string to lowercase snake_case
  toSnakeCase = str:
    let
      lower = lib.toLower str;
    in
    builtins.replaceStrings
      [ " " "-" "." "/" ":" "(" ")" "[" "]" "," "+" "@" "#" "$" "%" "^" "&" "*" ]
      [ "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" "_" ]
      lower;

  # Normalize string to lowercase kebab-case
  toKebabCase = str:
    let
      lower = lib.toLower str;
    in
    builtins.replaceStrings
      [ " " "_" "." "/" ":" "(" ")" "[" "]" "," "+" "@" "#" "$" "%" "^" "&" "*" ]
      [ "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" ]
      lower;

  # Extract components from a dependsOn list
  extractComponentsFromRoot = root: defaultUrlBase: release: update:
    if builtins.isAttrs root && root ? dependsOn then
      builtins.concatMap (dep:
        if builtins.isAttrs dep && dep ? component then
          let
            rawList = if builtins.isList dep.component then dep.component else [ dep.component ];
          in
          builtins.filter (c: builtins.isAttrs c && c ? componentFileName) rawList
        else []
      ) (if builtins.isList root.dependsOn then root.dependsOn else [ root.dependsOn ])
    else [];

  # Format component into normalized structure
  formatComponent = c: defaultUrlBase: release: update: hashes:
    let
      fn = builtins.elemAt (c.componentFileName or [ "" ]) 0;
      url =
        if c ? url && (builtins.elemAt c.url 0) != "" then
          builtins.elemAt c.url 0
        else
          "${defaultUrlBase}/${release}/Release/${update}/licensed_software/components/complete/${fn}";
      docVal = builtins.elemAt (c.doc or [ "0" ]) 0;
      isDoc = docVal == "1";
      name = builtins.elemAt (c.name or [ fn ]) 0;
      ver = builtins.elemAt (c.version or [ "" ]) 0;
      sha = hashes.${fn} or "";
    in {
      inherit fn url isDoc name ver;
      sha256 = sha;
      raw = c;
    };

  # Load all releases and their availableUpdates from versions.json
  loadVersions = dataDir:
    let
      raw = builtins.fromJSON (builtins.readFile (dataDir + "/versions.json"));
      filtered = builtins.filter (v: (v ? availableUpdates) && (builtins.length v.availableUpdates > 0)) raw;
    in
    filtered;

  # Load the signing key from data/key.txt
  loadKey = dataDir:
    let
      rawKey = builtins.readFile (dataDir + "/key.txt");
    in
    lib.strings.trim rawKey;

  # Load root hashes from data/hashes.json
  loadHashes = dataDir:
    let
      hashesFile = dataDir + "/hashes.json";
    in
    if builtins.pathExists hashesFile then
      builtins.fromJSON (builtins.readFile hashesFile)
    else
      {};

  # Load products and components for a specific release and update
  loadReleaseData = { dataDir ? ../data, system ? "x86_64-linux", release, update, urlBase ? "https://esd.mathworks.com", hashes ? loadHashes dataDir }:
    let
      platform = systemToPlatform.${system} or "glnxa64";
      releaseUpdateDir = dataDir + "/${release}.${update}";

      commonDir = releaseUpdateDir + "/common";
      archDir = releaseUpdateDir + "/${platform}";
      
      commonFiles =
        if builtins.pathExists commonDir then
          builtins.filter
            (f: builtins.match "^productdata_.*_common\\.json$" f != null)
            (builtins.attrNames (builtins.readDir commonDir))
        else
          [];

      parseProductFile = f:
        let
          baseMatch = builtins.match "^productdata_(.*)_common\\.json$" f;
          baseName = if baseMatch != null then builtins.elemAt baseMatch 0 else f;
          
          commonContent = builtins.fromJSON (builtins.readFile (commonDir + "/${f}"));
          pdata = commonContent.productData or {};
          pName = builtins.elemAt (pdata.productName or [ baseName ]) 0;
          pCode = builtins.elemAt (pdata.productBaseCode or [ "" ]) 0;
          pVer = builtins.elemAt (pdata.productVersion or [ "" ]) 0;

          commonCompsRaw = extractComponentsFromRoot pdata urlBase release update;

          # Check arch file
          archFile = archDir + "/productdata_${baseName}_${platform}.json";
          archCompsRaw =
            if builtins.pathExists archFile then
              let
                archContent = builtins.fromJSON (builtins.readFile archFile);
              in
              extractComponentsFromRoot (archContent.productAdditionalComps or {}) urlBase release update
            else
              [];

          allCompsRaw = commonCompsRaw ++ archCompsRaw;
          formattedComps = map (c: formatComponent c urlBase release update hashes) allCompsRaw;

          # Deduplicate components by fn
          dedupComps =
            builtins.attrValues (
              builtins.foldl' (acc: c:
                if c.fn == "" then acc
                else acc // { "${c.fn}" = c; }
              ) {} formattedComps
            );

          # Generate aliases for this product
          aliases = builtins.filter (a: a != "") (lib.unique [
            pName
            baseName
            pCode
            (toSnakeCase pName)
            (toKebabCase pName)
            (toSnakeCase baseName)
            (toKebabCase baseName)
            (lib.toLower pCode)
          ]);
        in {
          name = pName;
          baseName = baseName;
          code = pCode;
          version = pVer;
          components = dedupComps;
          aliases = aliases;
        };

      productList = map parseProductFile commonFiles;

      # Build the products map where each alias points to the product
      # Also provide canonical list of unique products
      uniqueProductsMap =
        builtins.foldl' (acc: prod:
          acc // { "${prod.name}" = prod; }
        ) {} productList;

      aliasedProductsMap =
        builtins.foldl' (acc: prod:
          let
            aliasEntries = builtins.foldl' (aAcc: alias:
              aAcc // { "${alias}" = prod; }
            ) {} prod.aliases;
          in
          acc // aliasEntries
        ) {} productList;

    in {
      inherit release update platform hashes productList;
      products = aliasedProductsMap;
      uniqueProducts = uniqueProductsMap;
    };

in {
  inherit systemToPlatform toSnakeCase toKebabCase loadVersions loadKey loadHashes loadReleaseData;
}
