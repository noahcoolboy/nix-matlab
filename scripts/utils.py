import hashlib, struct, time, urllib.parse
from pathlib import Path

import requests

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

def form_path(urlBase, release: str, phase = "Release", update = "5", category = "licensed_software", filename = "dws.zip"):
    return f"{urlBase}/{release}/{phase}/{update}/{category}/components/complete/{filename}"

def sign(key, url, ttl = 345600):
    url_parts = urllib.parse.urlparse(url)

    scheme = url_parts.scheme
    hostname = url_parts.netloc
    path = url_parts.path

    exp = int(time.time()) + ttl
    signature = hashlib.md5(struct.pack("<I", exp) + path.encode() + key)
    signature = hashlib.md5(key + signature.digest())
    return f"{scheme}://{hostname}{path}?__gda__={exp}_{signature.hexdigest()}"

def hash(url, headers=None):
    # Digest the bytes as they go over the wire. Nix stores the response body
    # verbatim, so any transparent decompression here (requests does it for
    # gzipped responses) yields a digest that fails the fixed-output check.
    merged = dict(headers or {})
    merged["Accept-Encoding"] = "identity"
    h = hashlib.sha256()
    with requests.get(url, stream=True, headers=merged) as response:
        response.raise_for_status()
        for chunk in response.raw.stream(1024 * 1024, decode_content=False):
            if chunk:
                h.update(chunk)
    return h.hexdigest()
