import hashlib
import zipfile, io, re, struct, sys, math, time, json, os, datetime

# Get version info
n = 2025 * 2 + 1
while n < datetime.date.today().year * 2 + 2:
    ver = f"R{n // 2}{["a", "b"][n % 2]}"
    print(ver)
    print(os.system(f"LD_PRELOAD={os.getcwd()}/hook.so ./mpm install --release={ver} /"))
    n += 1

# Get key from mpm
data = open("mpm", "rb").read()
for m in reversed(list(re.finditer(b"PK\x05\x06", data))):
    j = m.start()
    if j + 22 > len(data): continue
    clen, = struct.unpack("<H", data[j+20:j+22])
    try:
        z = zipfile.ZipFile(io.BytesIO(data[:j+22+clen]))
        break
    except zipfile.BadZipFile:
        continue

if not z:
    sys.exit("no usable zip payload found in mpm")

with z.open('bin/glnxa64/libmwinstall_akamai_token.so') as src:
    data = src.read()

def sections(elf):
    e_shoff, = struct.unpack("<Q", elf[0x28:0x30])
    e_shentsize, e_shnum, e_shstrndx = struct.unpack("<HHH", elf[0x3a:0x40])
    sh = [elf[e_shoff+i*e_shentsize: e_shoff+(i+1)*e_shentsize] for i in range(e_shnum)]
    #name_off, = struct.unpack("<Q", sh[e_shstrndx][0x18:0x20])
    strtab_off = struct.unpack("<Q", sh[e_shstrndx][0x18:0x20])[0]
    out = []
    for s in sh:
        nmoff, = struct.unpack("<I", s[0:4])
        off, size = struct.unpack("<QQ", s[0x18:0x28])
        end = elf.index(b"\0", strtab_off+nmoff)
        out.append((elf[strtab_off+nmoff:end].decode("latin1"), off, size))
    return out

def find_key(elf):
    cands = []
    for name, off, size in sections(elf):
        if not name.startswith(".rodata"): continue
        blob = elf[off:off+size]
        for m in re.finditer(rb"[\x21-\x7e]{24,128}\x00", blob):
            s = m.group()[:-1]
            if re.fullmatch(rb"[A-Za-z0-9]{24,128}", s) and re.search(rb"[0-9]", s) and re.search(rb"[A-Z]", s):
                cands.append(s)
    
    def score(s):
        f = [s.count(b) for b in set(s)]
        H = -sum((c/len(s))*math.log2(c/len(s)) for c in f)
        return H * min(len(s), 64)
    cands.sort(key=score, reverse=True)
    return cands[0]

key = find_key(data)
print(key)

URL = "https://esd.mathworks.com"
def sign(release: str, phase = "Release", update = "5", category = "licensed_software", filename = "dws.zip"):
    path = f"/{release}/{phase}/{update}/{category}/components/complete/{filename}"
    exp = int(time.time()) + 345600
    signature = hashlib.md5(struct.pack("<I", exp) + path.encode() + key)
    signature = hashlib.md5(key + signature.digest())
    return f"{URL}{path}?__gda__={exp}_{signature.hexdigest()}"

path = "/R2026a/Release/5/licensed_software/components/complete/dws.zip"
signed = sign("R2026a")
print(signed)