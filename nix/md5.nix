let
  # 32-bit arithmetic & bitwise operations
  mask32 = 4294967295;
  add32 = a: b: builtins.bitAnd (a + b) mask32;
  not32 = a: builtins.bitXor a mask32;
  and32 = builtins.bitAnd;
  or32 = builtins.bitOr;
  xor32 = builtins.bitXor;

  pow2 = [
    1 2 4 8 16 32 64 128 256 512 1024 2048 4096 8192 16384 32768
    65536 131072 262144 524288 1048576 2097152 4194304 8388608
    16777216 33554432 67108864 134217728 268435456 536870912 1073741824 2147483648
  ];

  leftRotate32 = x: s:
    let
      p_s = builtins.elemAt pow2 s;
      p_inv = builtins.elemAt pow2 (32 - s);
      left = builtins.bitAnd (x * p_s) mask32;
      right = (builtins.bitAnd x mask32) / p_inv;
    in
    builtins.bitOr left right;

  K = [
    3614090360 3905402710 606105819 3250441966 4118548399 1200080426 2821735955 4249261313
    1770035416 2336552879 4294925233 2304563134 1804603682 4254626195 2792965006 1236535329
    4129170786 3225465664 643717713 3921069994 3593408605 38016083 3634488961 3889429448
    568446438 3275163606 4107603335 1163531501 2850285829 4243563512 1735328473 2368359562
    4294588738 2272392833 1839030562 4259657740 2763975236 1272893353 4139469664 3200236656
    681279174 3936430074 3572445317 76029189 3654602809 3873151461 530742520 3299628645
    4096336452 1126891415 2878612391 4237533241 1700485571 2399980690 4293915773 2240044497
    1873313359 4264355552 2734768916 1309151649 4149444226 3174756917 718787259 3951481745
  ];

  S = [
    7 12 17 22  7 12 17 22  7 12 17 22  7 12 17 22
    5  9 14 20  5  9 14 20  5  9 14 20  5  9 14 20
    4 11 16 23  4 11 16 23  4 11 16 23  4 11 16 23
    6 10 15 21  6 10 15 21  6 10 15 21  6 10 15 21
  ];

  # Full ASCII mapping for char to byte
  asciiTable = {
    "\t" = 9; "\n" = 10; "\r" = 13; " " = 32; "!" = 33; "\"" = 34; "#" = 35;
    "$" = 36; "%" = 37; "&" = 38; "'" = 39; "(" = 40; ")" = 41; "*" = 42;
    "+" = 43; "," = 44; "-" = 45; "." = 46; "/" = 47; "0" = 48; "1" = 49;
    "2" = 50; "3" = 51; "4" = 52; "5" = 53; "6" = 54; "7" = 55; "8" = 56;
    "9" = 57; ":" = 58; ";" = 59; "<" = 60; "=" = 61; ">" = 62; "?" = 63;
    "@" = 64; "A" = 65; "B" = 66; "C" = 67; "D" = 68; "E" = 69; "F" = 70;
    "G" = 71; "H" = 72; "I" = 73; "J" = 74; "K" = 75; "L" = 76; "M" = 77;
    "N" = 78; "O" = 79; "P" = 80; "Q" = 81; "R" = 82; "S" = 83; "T" = 84;
    "U" = 85; "V" = 86; "W" = 87; "X" = 88; "Y" = 89; "Z" = 90; "[" = 91;
    "\\" = 92; "]" = 93; "^" = 94; "_" = 95; "`" = 96; "a" = 97; "b" = 98;
    "c" = 99; "d" = 100; "e" = 101; "f" = 102; "g" = 103; "h" = 104;
    "i" = 105; "j" = 106; "k" = 107; "l" = 108; "m" = 109; "n" = 110;
    "o" = 111; "p" = 112; "q" = 113; "r" = 114; "s" = 115; "t" = 116;
    "u" = 117; "v" = 118; "w" = 119; "x" = 120; "y" = 121; "z" = 122;
    "{" = 123; "|" = 124; "}" = 125; "~" = 126;
  };

  stringToBytes = s:
    let
      chars = builtins.genList (i: builtins.substring i 1 s) (builtins.stringLength s);
    in
    map (c: asciiTable.${c} or 0) chars;

  hexChars = [ "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "b" "c" "d" "e" "f" ];
  byteToHex = b:
    "${builtins.elemAt hexChars (b / 16)}${builtins.elemAt hexChars (builtins.bitAnd b 15)}";

  bytesToHex = bytes:
    builtins.concatStringsSep "" (map byteToHex bytes);

  # Pad message to a multiple of 64 bytes
  padMD5 = bytes:
    let
      len = builtins.length bytes;
      lenBits = len * 8;
      mod64 = builtins.bitAnd (len + 1) 63;
      padZeros = if mod64 <= 56 then 56 - mod64 else 64 + 56 - mod64;
      zeroList = builtins.genList (_: 0) padZeros;
      lenByte = i: builtins.bitAnd (lenBits / (builtins.elemAt pow2 (i * 8))) 255;
      lenBytes = builtins.genList (i: if i < 4 then lenByte i else 0) 8;
    in
    bytes ++ [ 128 ] ++ zeroList ++ lenBytes;

  # Build 16 32-bit little-endian integers from a 64-byte block
  blockToWords = block:
    builtins.genList (i:
      let
        b0 = builtins.elemAt block (i * 4);
        b1 = builtins.elemAt block (i * 4 + 1);
        b2 = builtins.elemAt block (i * 4 + 2);
        b3 = builtins.elemAt block (i * 4 + 3);
      in
      or32 (or32 (or32 b0 (b1 * 256)) (b2 * 65536)) (b3 * 16777216)
    ) 16;

  # MD5 compression step
  stepRound = M: state: i:
    let
      A = state.A;
      B = state.B;
      C = state.C;
      D = state.D;

      f_and_g =
        if i < 16 then {
          F = or32 (and32 B C) (and32 (not32 B) D);
          g = i;
        } else if i < 32 then {
          F = or32 (and32 D B) (and32 (not32 D) C);
          g = builtins.bitAnd (5 * i + 1) 15;
        } else if i < 48 then {
          F = xor32 (xor32 B C) D;
          g = builtins.bitAnd (3 * i + 5) 15;
        } else {
          F = xor32 C (or32 B (not32 D));
          g = builtins.bitAnd (7 * i) 15;
        };

      F_val = f_and_g.F;
      g_val = f_and_g.g;
      k_val = builtins.elemAt K i;
      s_val = builtins.elemAt S i;
      m_val = builtins.elemAt M g_val;

      sum = add32 (add32 (add32 F_val A) k_val) m_val;
      newB = add32 B (leftRotate32 sum s_val);
    in {
      A = D;
      B = newB;
      C = B;
      D = C;
    };

  processBlock = block: state:
    let
      M = blockToWords block;
      res = builtins.foldl' (s: i: stepRound M s i) state (builtins.genList (i: i) 64);
    in {
      a0 = add32 state.a0 res.A;
      b0 = add32 state.b0 res.B;
      c0 = add32 state.c0 res.C;
      d0 = add32 state.d0 res.D;
      A = add32 state.a0 res.A;
      B = add32 state.b0 res.B;
      C = add32 state.c0 res.C;
      D = add32 state.d0 res.D;
    };

  # Convert 32-bit integer to 4 little-endian bytes
  wordToBytes = w: [
    (builtins.bitAnd w 255)
    (builtins.bitAnd (w / 256) 255)
    (builtins.bitAnd (w / 65536) 255)
    (builtins.bitAnd (w / 16777216) 255)
  ];

  md5Bytes = data:
    let
      rawBytes = if builtins.isString data then stringToBytes data else data;
      padded = padMD5 rawBytes;
      numBlocks = (builtins.length padded) / 64;
      initState = {
        a0 = 1732584193; # 0x67452301
        b0 = 4023233417; # 0xefcdab89
        c0 = 2562383102; # 0x98badcfe
        d0 = 271733878;  # 0x10325476
        A = 1732584193;
        B = 4023233417;
        C = 2562383102;
        D = 271733878;
      };
      finalState = builtins.foldl' (state: blockIdx:
        let
          block = builtins.genList (i: builtins.elemAt padded (blockIdx * 64 + i)) 64;
        in
        processBlock block state
      ) initState (builtins.genList (i: i) numBlocks);
    in
    builtins.concatMap wordToBytes [ finalState.a0 finalState.b0 finalState.c0 finalState.d0 ];

  md5Hex = data: bytesToHex (md5Bytes data);

in {
  inherit md5Bytes md5Hex stringToBytes bytesToHex byteToHex wordToBytes;
}
