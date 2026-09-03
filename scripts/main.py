import json
import io
import zipfile
import xml.etree.ElementTree as ET
import os
import requests

from key import get_key
from versions import get_versions
from utils import sign, hash, xml_to_json, form_path
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import subprocess

try:
    import zstandard as zstd
    def decompress_zstd(data: bytes) -> bytes:
        return zstd.ZstdDecompressor().stream_reader(io.BytesIO(data)).read()
    def compress_zstd(data: bytes) -> bytes:
        return zstd.ZstdCompressor(level=19, write_content_size=True).compress(data)
except ImportError:
    def decompress_zstd(data: bytes) -> bytes:
        p = subprocess.run(["zstd", "-d", "-c"], input=data, capture_output=True, check=True)
        return p.stdout
    def compress_zstd(data: bytes) -> bytes:
        p = subprocess.run(["zstd", "-19", "-c"], input=data, capture_output=True, check=True)
        return p.stdout

def load_release_hashes(release: str) -> tuple[dict, Path]:
    zst_file = Path(f"data/{release}/hashes.json.zst")
    raw_file = Path(f"data/{release}/hashes.json")
    if zst_file.exists():
        with zst_file.open("rb") as f:
            return json.loads(decompress_zstd(f.read()).decode("utf-8")), zst_file
    elif raw_file.exists():
        with raw_file.open("r", encoding="utf-8") as f:
            return json.load(f), zst_file
    return {}, zst_file

def save_release_hashes(hashes: dict, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(hashes, indent=4).encode("utf-8")
    compressed = compress_zstd(raw)
    with path.open("wb") as f:
        f.write(compressed)

# Initialize key and versions
key = get_key()
versions = get_versions()
headers = {
    "User-Agent": "nix-matlab/1.0 (+https://github.com/noahcoolboy/nix-matlab)",
    "Accept-Encoding": "identity",
}

# Initialize data
os.makedirs("data", exist_ok=True)
with open("data/key.txt", "w") as f:
    f.write(key.decode("utf-8"))
with open("data/versions.json", "w") as f:
    json.dump(versions, f, indent=4)

# Get hashin'
def fetch_hash(item):
    component, url, ttl = item
    return component, hash(sign(key, url, ttl=ttl), headers=headers)

quota = 5000

with ThreadPoolExecutor(max_workers=8) as pool:
    for ver in versions:
        if quota <= 0:
            break
        if not ver.get("availableUpdates"):
            continue

        release = ver["release"]
        hashes, hashes_file = load_release_hashes(release)
        new_hashes = 0

        for update in ver["availableUpdates"]:
            if quota <= 0:
                break
            path = Path(f"data/{release}.{update}")
            path.mkdir(parents=True, exist_ok=True)
            signedDws = sign(key, form_path(ver["urlBase"], release, "Release", update), ttl=ver["urlSigning"]["ttlSeconds"])
            response = requests.get(signedDws, headers=headers)
            response.raise_for_status()
            dws = zipfile.ZipFile(io.BytesIO(response.content))

            for name in dws.namelist():
                if not name.endswith(".xml"):
                    continue
                root = ET.parse(dws.open(name)).getroot()

                file_path = Path(f"{path}/{name[:-4]}.json")
                file_path.parent.mkdir(parents=True, exist_ok=True)
                
                if root.tag == "componentData":
                    components = root.findall("component")
                elif root.tag in ("productData", "productAdditionalComps", "productOptionalComps"):
                    components = [c for d in root.findall("dependsOn") for c in d.findall("component")]
                else:
                    components = []

                jobs = []
                for component in components:
                    fn = component.find("componentFileName")
                    if fn is None or not fn.text:
                        continue
                    url = form_path(ver["urlBase"], release, "Release", update, "licensed_software", fn.text)
                    ET.SubElement(component, "url").text = url
                    if fn.text not in hashes and quota > 0:
                        jobs.append((component, url, ver["urlSigning"]["ttlSeconds"]))

                if jobs:
                    jobs_to_run = jobs[:quota]
                    quota -= len(jobs_to_run)
                    for component, sha in pool.map(fetch_hash, jobs_to_run):
                        c_fn = component.find("componentFileName").text
                        print(c_fn, sha)
                        hashes[c_fn] = sha
                        new_hashes += 1

                if jobs or not file_path.exists():
                    with file_path.open("w", encoding="utf-8") as f:
                        json.dump(xml_to_json(root), f, indent=4)

            if new_hashes > 0:
                save_release_hashes(hashes, hashes_file)

        if not hashes_file.exists():
            save_release_hashes(hashes, hashes_file)
