import datetime
import json
import os
from pathlib import Path
import subprocess

VERSIONS_FILE = Path(__file__).resolve().parent.parent / "data" / "versions.json"

def extract_json_objects(text):
    decoder = json.JSONDecoder()
    objs, i = [], 0
    while i < len(text):
        while i < len(text) and text[i] not in "{[":
            i += 1
        if i >= len(text):
            break
        try:
            obj, end = decoder.raw_decode(text, i)
            objs.append(obj)
            i = end
        except json.JSONDecodeError:
            i += 1
    return objs

def get_versions():
    if not (Path("./mpm").exists() and Path("./hook.so").exists()):
        if VERSIONS_FILE.exists():
            return json.loads(VERSIONS_FILE.read_text(encoding="utf-8"))
    versions = []
    n = 2025 * 2 + 1
    while n < datetime.date.today().year * 2 + 2:
        ver = f"R{n // 2}{'a' if n % 2 == 0 else 'b'}"
        
        proc = subprocess.run(
            ["./mpm", "install", f"--release={ver}", "--destination", ".", "/"],
            stderr=subprocess.PIPE,
            env={
                "LD_PRELOAD": os.path.join(os.getcwd(), "hook.so"),
            },
        )
        
        objs = extract_json_objects(proc.stderr.decode("utf-8", errors="replace"))
        with open("versions.jsonl", "a") as f:
            for obj in objs:
                if obj.get("code") == "BadRequest":
                    continue
                obj["release"] = ver
                f.write(json.dumps(obj) + "\n")
                versions.append(obj)
        n += 1

    return versions