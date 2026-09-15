import io
import math
from pathlib import Path
import re
import struct
import sys
import zipfile

KEY_FILE = Path(__file__).resolve().parent.parent / "data" / "key.txt"

def get_zip(data):
    for m in reversed(list(re.finditer(b"PK\x05\x06", data))):
        j = m.start()
        if j + 22 > len(data):
            continue
        clen, = struct.unpack("<H", data[j + 20:j + 22])
        try:
            return zipfile.ZipFile(io.BytesIO(data[:j + 22 + clen]))
        except zipfile.BadZipFile:
            continue

def sections(elf):
    e_shoff, = struct.unpack("<Q", elf[0x28:0x30])
    e_shentsize, e_shnum, e_shstrndx = struct.unpack("<HHH", elf[0x3a:0x40])
    sh = [elf[e_shoff + i * e_shentsize: e_shoff + (i + 1) * e_shentsize] for i in range(e_shnum)]
    strtab_off = struct.unpack("<Q", sh[e_shstrndx][0x18:0x20])[0]
    out = []
    for s in sh:
        nmoff, = struct.unpack("<I", s[0:4])
        off, size = struct.unpack("<QQ", s[0x18:0x28])
        end = elf.index(b"\0", strtab_off + nmoff)
        out.append((elf[strtab_off + nmoff:end].decode("latin1"), off, size))
    return out

def find_key(elf):
    cands = []
    for name, off, size in sections(elf):
        if not name.startswith(".rodata"):
            continue
        blob = elf[off:off + size]
        for m in re.finditer(rb"[\x21-\x7e]{24,128}\x00", blob):
            s = m.group()[:-1]
            if re.fullmatch(rb"[A-Za-z0-9]{24,128}", s) and re.search(rb"[0-9]", s) and re.search(rb"[A-Z]", s):
                cands.append(s)

    def score(s):
        f = [s.count(b) for b in set(s)]
        H = -sum((c / len(s)) * math.log2(c / len(s)) for c in f)
        return H * min(len(s), 64)

    cands.sort(key=score, reverse=True)
    return cands[0]

def get_key():
    mpm_path = Path("./mpm")
    if not mpm_path.exists() and KEY_FILE.exists():
        return KEY_FILE.read_text(encoding="utf-8").strip().encode("utf-8")
    data = mpm_path.read_bytes()
    z = get_zip(data)
    if not z:
        sys.exit("no usable zip payload found in mpm")
    with z.open("bin/glnxa64/libmwinstall_akamai_token.so") as src:
        data = src.read()
    return find_key(data)