import hashlib, struct, time, urllib.parse
import requests

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
    h = hashlib.sha256()
    with requests.get(url, stream=True, headers=headers) as response:
        response.raise_for_status()
        for chunk in response.iter_content(1024 * 1024):
            if chunk:
                h.update(chunk)
    return h.hexdigest()

def xml_to_json(elem):
    tag = elem.tag.split("}")[-1]
    children = list(elem)
    text = (elem.text or "").strip()
    if not children and not elem.attrib:
        return {tag: text}
    out = dict(elem.attrib)
    for child in children:
        val = xml_to_json(child)
        child_tag = child.tag.split("}")[-1]
        val = val[child_tag] if isinstance(val, dict) and set(val) == {child_tag} else val
        if child_tag in out:
            out[child_tag].append(val)
        else:
            out[child_tag] = [val]
    if text:
        out["#text"] = text
    return {tag: out}