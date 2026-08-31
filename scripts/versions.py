import json, subprocess, os, datetime

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
    versions = []
    n = 2025 * 2 + 1
    while n < datetime.date.today().year * 2 + 2:
        ver = f"R{n // 2}{["a", "b"][n % 2]}"
        
        proc = subprocess.run(
            ["./mpm", "install", f"--release={ver}", "--destination", ".", "/"],
            stderr=subprocess.PIPE,
            env={
                "LD_PRELOAD": os.path.join(os.getcwd(), "hook.so"),
            },
        )
        
        objs = extract_json_objects(proc.stderr.decode("utf-8", errors="replace"))
        with open(f"versions.jsonl", "a") as f:
            for obj in objs:
                if obj.get("code") == "BadRequest":
                    continue
                obj["release"] = ver
                f.write(json.dumps(obj) + "\n")
                versions.append(obj)
        n += 1

    return versions