let
  md5 = import ./md5.nix;

  parseUrl = url:
    let
      match = builtins.match "^([a-zA-Z]+)://([^/]+)(/.*)$" url;
    in
    if match != null then {
      scheme = builtins.elemAt match 0;
      hostname = builtins.elemAt match 1;
      path = builtins.elemAt match 2;
    } else {
      scheme = "";
      hostname = "";
      path = url;
    };

  # Sign a URL matching utils.py: sign(key, url, ttl)
  # Uses 2147483647 (0x7fffffff, max signed 32-bit timestamp) by default
  # so Akamai token authentication accepts the expiration timestamp (4294967295 / 0xffffffff
  # overflows 32-bit signed int on Akamai edge servers resulting in 403 Forbidden).
  signUrl = { key, url, exp ? 2147483647 }:
    let
      parsed = parseUrl url;
      cleanKey = if builtins.isString key then key else toString key;
      keyBytes = md5.stringToBytes cleanKey;
      pathBytes = md5.stringToBytes parsed.path;

      expBytes = md5.wordToBytes exp;

      # Signature stage 1: md5(struct.pack("<I", exp) + path.encode() + key)
      sig1Digest = md5.md5Bytes (expBytes ++ pathBytes ++ keyBytes);

      # Signature stage 2: md5(key + sig1.digest())
      sig2Digest = md5.md5Bytes (keyBytes ++ sig1Digest);
      sig2Hex = md5.bytesToHex sig2Digest;
    in
    if parsed.scheme != "" then
      "${parsed.scheme}://${parsed.hostname}${parsed.path}?__gda__=${toString exp}_${sig2Hex}"
    else
      "${parsed.path}?__gda__=${toString exp}_${sig2Hex}";

in {
  inherit signUrl parseUrl;
}
