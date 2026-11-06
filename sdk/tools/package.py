#!/usr/bin/env python3
"""Build the SDK packages into sdk/dist/ (nothing is published). No dependencies:

  sdk/dist/lumora_bot-<v>-py3-none-any.whl   Python wheel      (pip install <file>)
  sdk/dist/lumora_bot-<v>.tar.gz             Python sdist      (pip install <file>; builds with setuptools)
  sdk/dist/lumora-bot-<v>.tgz                npm package       (npm install <file>)

Also writes sdk/js/lumora-bot.d.mts (copy of lumora-bot.d.ts for files imported by path).

The Python SDK is one file (sdk/python/lumora_bot.py, also downloadable as is). PEP 561 typing
markers only work for packages, so the wheel and the sdist ship it as the package
`lumora_bot/__init__.py` + `lumora_bot/py.typed` (marker: sdk/python/py.typed); `import lumora_bot`
is unchanged.

Also copies sdk/LICENSE and sdk/CHANGELOG.md into both package folders and checks that the
version is the same in lumora_bot.py, pyproject.toml, lumora-bot.mjs and package.json.
Archives are reproducible (fixed timestamps, sorted entries).

    python3 sdk/tools/package.py
"""
import base64
import gzip
import hashlib
import io
import json
import re
import shutil
import sys
import tarfile
import zipfile
from pathlib import Path

SDK = Path(__file__).resolve().parents[1]
DIST = SDK / "dist"
EPOCH = 1767225600  # 2026-01-01, fixed for reproducible archives


def versions():
    py = re.search(r'^__version__ = "([^"]+)"', (SDK / "python" / "lumora_bot.py").read_text(encoding="utf-8"), re.M).group(1)
    toml = re.search(r'^version = "([^"]+)"', (SDK / "python" / "pyproject.toml").read_text(encoding="utf-8"), re.M).group(1)
    js = re.search(r'export const VERSION = "([^"]+)"', (SDK / "js" / "lumora-bot.mjs").read_text(encoding="utf-8")).group(1)
    pkg = json.loads((SDK / "js" / "package.json").read_text(encoding="utf-8"))["version"]
    return {"lumora_bot.py": py, "pyproject.toml": toml, "lumora-bot.mjs": js, "package.json": pkg}


def project():
    text = (SDK / "python" / "pyproject.toml").read_text(encoding="utf-8")
    try:
        import tomllib
        return tomllib.loads(text)["project"]
    except ImportError:  # Python < 3.11: the few fields we need
        get = lambda k: re.search(rf'^{k} = "([^"]*)"', text, re.M).group(1)  # noqa: E731
        return {"name": get("name"), "version": get("version"), "description": get("description"),
                "requires-python": get("requires-python"), "license": {"text": re.search(r'license = \{ text = "([^"]+)"', text).group(1)},
                "classifiers": re.findall(r'^\s+"([^"]+ :: [^"]+)",', text, re.M),
                "urls": dict(re.findall(r'^(\w+) = "(https://[^"]+)"', text, re.M)), "keywords": []}


def metadata(p):
    lines = ["Metadata-Version: 2.1", f"Name: {p['name']}", f"Version: {p['version']}", f"Summary: {p['description']}",
             "Author: Lumora", f"License: {p['license']['text']}", f"Requires-Python: {p['requires-python']}"]
    if p.get("keywords"):
        lines.append("Keywords: " + ",".join(p["keywords"]))
    lines += [f"Classifier: {c}" for c in p.get("classifiers", [])]
    lines += [f"Project-URL: {k}, {v}" for k, v in p.get("urls", {}).items()]
    lines.append("Description-Content-Type: text/markdown")
    return "\n".join(lines) + "\n\n" + (SDK / "python" / "README.md").read_text(encoding="utf-8")


def wheel(p, out):
    name, ver = "lumora_bot", p["version"]
    di = f"{name}-{ver}.dist-info"
    files = {
        "lumora_bot/__init__.py": (SDK / "python" / "lumora_bot.py").read_bytes(),
        "lumora_bot/py.typed": (SDK / "python" / "py.typed").read_bytes(),
        f"{di}/METADATA": metadata(p).encode(),
        f"{di}/WHEEL": b"Wheel-Version: 1.0\nGenerator: lumora sdk/tools/package.py\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        f"{di}/top_level.txt": b"lumora_bot\n",
        f"{di}/licenses/LICENSE": (SDK / "LICENSE").read_bytes(),
    }
    record = []
    for path, data in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        record.append(f"{path},sha256={digest},{len(data)}")
    record.append(f"{di}/RECORD,,")
    files[f"{di}/RECORD"] = ("\n".join(record) + "\n").encode()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path, data in files.items():
            zi = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            zi.external_attr = 0o644 << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)


def targz(out, root, entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for arc, data in sorted(entries.items()):
            ti = tarfile.TarInfo(f"{root}/{arc}")
            ti.size, ti.mtime, ti.mode, ti.uname, ti.gname = len(data), EPOCH, 0o644, "", ""
            t.addfile(ti, io.BytesIO(data))
    with open(out, "wb") as f, gzip.GzipFile(fileobj=f, mode="wb", mtime=EPOCH, filename="") as g:
        g.write(buf.getvalue())


def sdist(p, out):
    py = SDK / "python"
    entries = {f: (py / f).read_bytes() for f in ("README.md", "LICENSE", "CHANGELOG.md")}
    # package layout (see the module docstring): setuptools needs packages + package-data
    toml = (py / "pyproject.toml").read_text(encoding="utf-8")
    flat = 'py-modules = ["lumora_bot"]'
    if flat not in toml:
        sys.exit(f"pyproject.toml: expected {flat!r}")
    toml = toml.replace(flat, 'packages = ["lumora_bot"]\npackage-data = { lumora_bot = ["py.typed"] }')
    entries["pyproject.toml"] = toml.encode()
    entries["lumora_bot/__init__.py"] = (py / "lumora_bot.py").read_bytes()
    entries["lumora_bot/py.typed"] = (py / "py.typed").read_bytes()
    entries["PKG-INFO"] = metadata(p).encode()
    targz(out, f"lumora_bot-{p['version']}", entries)


def npm_pack(out):
    js = SDK / "js"
    pkg = json.loads((js / "package.json").read_text(encoding="utf-8"))
    entries = {"package.json": (js / "package.json").read_bytes()}
    for f in pkg["files"]:
        entries[f] = (js / f).read_bytes()
    targz(out, "package", entries)


def main():
    v = versions()
    if len(set(v.values())) != 1:
        sys.exit(f"version mismatch: {v}")
    version = next(iter(v.values()))
    for d in ("python", "js"):
        for f in ("LICENSE", "CHANGELOG.md"):
            shutil.copyfile(SDK / f, SDK / d / f)
    # TypeScript looks for "<name>.d.mts" next to an .mjs file that is imported by path
    shutil.copyfile(SDK / "js" / "lumora-bot.d.ts", SDK / "js" / "lumora-bot.d.mts")
    p = project()
    tmp = DIST.with_name("dist.tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()
    wheel(p, tmp / f"lumora_bot-{version}-py3-none-any.whl")
    sdist(p, tmp / f"lumora_bot-{version}.tar.gz")
    npm_pack(tmp / f"lumora-bot-{version}.tgz")
    shutil.rmtree(DIST, ignore_errors=True)
    tmp.rename(DIST)
    for f in sorted(DIST.iterdir()):
        print(f"{f.name}  {f.stat().st_size} bytes  sha256 {hashlib.sha256(f.read_bytes()).hexdigest()[:16]}…")
    print(f"lumora-bot {version}: packages in {DIST}")


if __name__ == "__main__":
    main()
