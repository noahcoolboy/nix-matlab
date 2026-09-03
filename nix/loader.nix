{ lib ? (import <nixpkgs> { }).lib }:

let
  systemToPlatform = {
    "x86_64-linux" = "glnxa64";
    "aarch64-linux" = "glnxa64";
    "x86_64-darwin" = "maci64";
    "aarch64-darwin" = "maca64";
    "x86_64-windows" = "win64";
    "i686-windows" = "win64";
  };

  # Helper to parse a JSON file
  loadJson = file: builtins.fromJSON (builtins.readFile file);

  # Separator characters replaced during case normalization
  sepChars = [ " " "-" "_" "." "/" ":" "(" ")" "[" "]" "," "+" "@" "#" "$" "%" "^" "&" "*" ];
  replaceSep = sep: str:
    builtins.replaceStrings sepChars (builtins.genList (_: sep) (builtins.length sepChars)) (lib.toLower str);

  # Normalize string to lowercase snake_case or kebab-case
  toSnakeCase = replaceSep "_";
  toKebabCase = replaceSep "-";

  # Deduplicate component records by filename
  dedupComponents = comps:
    builtins.attrValues (
      builtins.listToAttrs (
        map (c: { name = c.fn; value = c; })
          (builtins.filter (c: c.fn != "") comps)
      )
    );

  # Extract components from a dependsOn list
  extractComponentsFromRoot = root:
    if builtins.isAttrs root && root ? dependsOn then
      builtins.concatMap (dep:
        if builtins.isAttrs dep && dep ? component then
          builtins.filter (c: builtins.isAttrs c && c ? componentFileName) (lib.toList dep.component)
        else []
      ) (lib.toList root.dependsOn)
    else [];

  # Format component into normalized structure
  formatComponent = defaultUrlBase: release: update: hashes: c:
    let
      fn = builtins.head (c.componentFileName or [ "" ]);
      url =
        if c ? url && (builtins.head c.url) != "" then
          builtins.head c.url
        else
          "${defaultUrlBase}/${release}/Release/${update}/licensed_software/components/complete/${fn}";
      docVal = builtins.head (c.doc or [ "0" ]);
      isDoc = docVal == "1";
      name = builtins.head (c.name or [ fn ]);
      ver = builtins.head (c.version or [ "" ]);
      sha256 = hashes.${fn} or "";
    in {
      inherit fn url isDoc name ver sha256;
      raw = c;
    };

  # Load all releases and their availableUpdates from versions.json
  loadVersions = dataDir:
    builtins.filter (v: (v.availableUpdates or []) != [])
      (loadJson (dataDir + "/versions.json"));

  # Load the signing key from data/key.txt
  loadKey = dataDir:
    lib.strings.trim (builtins.readFile (dataDir + "/key.txt"));

  # Load release hashes from data/<release>/hashes.json
  loadHashes = dataDir: release:
    let
      hashesFile = dataDir + "/${release}/hashes.json";
    in
    if builtins.pathExists hashesFile then
      loadJson hashesFile
    else
      {};

  # Load products and components for a specific release and update
  loadReleaseData = { dataDir ? ../data, system ? "x86_64-linux", release, update, urlBase ? "https://esd.mathworks.com", hashes ? loadHashes dataDir release }:
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

      formatComp = formatComponent urlBase release update hashes;

      parseProductFile = f:
        let
          baseMatch = builtins.match "^productdata_(.*)_common\\.json$" f;
          baseName = if baseMatch != null then builtins.head baseMatch else f;
          
          commonContent = loadJson (commonDir + "/${f}");
          pdata = commonContent.productData or {};
          pName = builtins.head (pdata.productName or [ baseName ]);
          pCode = builtins.head (pdata.productBaseCode or [ "" ]);
          pVer = builtins.head (pdata.productVersion or [ "" ]);

          commonCompsRaw = extractComponentsFromRoot pdata;

          # Check arch file
          archFile = archDir + "/productdata_${baseName}_${platform}.json";
          archCompsRaw =
            if builtins.pathExists archFile then
              let
                archContent = loadJson archFile;
              in
              extractComponentsFromRoot (archContent.productAdditionalComps or {})
            else
              [];

          allCompsRaw = commonCompsRaw ++ archCompsRaw;
          formattedComps = map formatComp allCompsRaw;
          dedupComps = dedupComponents formattedComps;

          # Generate aliases for this product
          aliases = builtins.filter (a: a != "") (lib.unique (
            [ pName baseName pCode (lib.toLower pCode) ]
            ++ builtins.concatMap (n: [ (toSnakeCase n) (toKebabCase n) ]) [ pName baseName ]
          ));
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
      uniqueProductsMap = builtins.listToAttrs (
        map (prod: { name = prod.name; value = prod; }) productList
      );

      aliasedProductsMap = builtins.listToAttrs (
        builtins.concatMap (prod:
          map (alias: { name = alias; value = prod; }) prod.aliases
        ) productList
      );

    in {
      inherit release update platform hashes productList;
      products = aliasedProductsMap;
      uniqueProducts = uniqueProductsMap;
    };

in {
  inherit systemToPlatform toSnakeCase toKebabCase loadJson dedupComponents loadVersions loadKey loadHashes loadReleaseData;
}
