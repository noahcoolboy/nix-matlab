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

# Initialize key and versions
key = get_key()
versions = get_versions()
headers = { "User-Agent": "nix-matlab/1.0 (+https://github.com/noahcoolboy/nix-matlab)" }

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
        for update in ver["availableUpdates"]:
            if quota <= 0:
                break
            path = Path(f"data/{ver['release']}.{update}")
            path.mkdir(parents=True, exist_ok=True)
            signedDws = sign(key, form_path(ver["urlBase"], ver["release"], "Release", update), ttl=ver["urlSigning"]["ttlSeconds"])
            response = requests.get(signedDws, headers=headers)
            response.raise_for_status()
            dws = zipfile.ZipFile(io.BytesIO(response.content))

            hashes = {}
            if (path / "hashes.json").exists():
                with (path / "hashes.json").open("r", encoding="utf-8") as f:
                    hashes = json.load(f)

            new_hashes = 0
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
                    url = form_path(ver["urlBase"], ver["release"], "Release", update, "licensed_software", fn.text)
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

            if new_hashes > 0 or not (path / "hashes.json").exists():
                with (path / "hashes.json").open("w", encoding="utf-8") as f:
                    json.dump(hashes, f, indent=4)