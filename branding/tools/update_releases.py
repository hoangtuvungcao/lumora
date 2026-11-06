#!/usr/bin/env python3
"""Fill landing/releases.json from a published GitHub release (url, sha256, size, available).

Run after the CI draft release in hoangtuvungcao/get_lumora has been reviewed and published:

    python3 branding/tools/update_releases.py --tag v1.0.0            # reads the release with `gh`
    python3 branding/tools/update_releases.py --tag v1.0.0 --sums SHA256SUMS --dir ./dist
                                                                      # offline: local files
    python3 branding/tools/build_pages.py && bash branding/tools/make_dist.sh   # then deploy

What it does, for every file listed in releases.json (platforms + tools):
  * name = its "file" with {version} filled in (the names the CI release job publishes);
  * found in the release and in SHA256SUMS → url (GitHub download link), sha256, size, bytes,
    available: true;
  * missing → available: false (and a warning), so the site never links a file that isn't there.
It also sets version and date, and copies the result into the inline fallback in
landing/assets/js/app.js (sync_fallback, also used by build_pages.py).

Checksums always come from SHA256SUMS (the file the release signs with cosign), never from
the GitHub API. With `gh`, the release must be published (not a draft) unless --allow-draft.
Optional: --mac-signed marks the macOS .dmg as signed + notarized (hides the "Open Anyway" note).
"""
import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASES = ROOT / "landing" / "releases.json"
APP_JS = ROOT / "landing" / "assets" / "js" / "app.js"
REPO = "hoangtuvungcao/get_lumora"
MARK = re.compile(r"/\*RELEASES-BEGIN\*/.*?/\*RELEASES-END\*/", re.S)


def sync_fallback(data=None):
    """Copy releases.json into app.js between the RELEASES markers. Returns True if app.js changed."""
    if data is None:
        data = json.loads(RELEASES.read_text(encoding="utf-8"))
    js = APP_JS.read_text(encoding="utf-8")
    if not MARK.search(js):
        sys.exit("app.js: RELEASES-BEGIN/END markers not found")
    blob = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    new = MARK.sub(lambda _m: f"/*RELEASES-BEGIN*/{blob}/*RELEASES-END*/", js, count=1)
    if new != js:
        APP_JS.write_text(new, encoding="utf-8")
        return True
    return False


def human(n):
    """Size as shown on the download page: 812 KB, 9.4 MB, 86 MB, 1.2 GB."""
    if n < 1024 * 1024:
        return f"{max(1, round(n / 1024))} KB"
    mb = n / 1024 / 1024
    if mb >= 1024:
        return f"{mb / 1024:.1f} GB"
    return f"{mb:.0f} MB" if mb >= 10 else f"{mb:.1f} MB"


def parse_sums(text):
    sums = {}
    for line in text.splitlines():
        m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+)$", line.strip())
        if m:
            sums[m.group(2).strip()] = m.group(1).lower()
    if not sums:
        sys.exit("SHA256SUMS: no checksum lines found")
    return sums


def gh(*args):
    try:
        return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    except FileNotFoundError:
        sys.exit("gh (GitHub CLI) is not installed; use --sums/--dir instead")
    except subprocess.CalledProcessError as e:
        sys.exit(f"gh {' '.join(args)} failed:\n{e.stderr.strip()}")


def from_github(tag, repo, allow_draft):
    info = json.loads(gh("release", "view", tag, "--repo", repo, "--json", "assets,isDraft,publishedAt,url,tagName"))
    if info.get("isDraft") and not allow_draft:
        sys.exit(f"{repo} {tag} is still a draft: publish it first (or pass --allow-draft for a dry run)")
    sizes = {a["name"]: int(a["size"]) for a in info.get("assets", [])}
    if "SHA256SUMS" not in sizes:
        sys.exit(f"{repo} {tag} has no SHA256SUMS asset")
    sums = parse_sums(gh("release", "download", tag, "--repo", repo, "--pattern", "SHA256SUMS", "--output", "-"))
    date = (info.get("publishedAt") or "")[:10] or dt.date.today().isoformat()
    return sizes, sums, date


def from_local(sums_path, folder):
    sums = parse_sums(Path(sums_path).read_text(encoding="utf-8")) if sums_path else {}
    sizes = {}
    if folder:
        for f in Path(folder).iterdir():
            if f.is_file():
                sizes[f.name] = f.stat().st_size
                if not sums_path:
                    sums[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
    return sizes, sums, dt.date.today().isoformat()


def all_files(data):
    for group in ("platforms", "tools"):
        for entry in data.get(group, {}).values():
            for f in entry.get("files", []):
                yield f


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tag", required=True, help="release tag, e.g. v1.0.0")
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--sums", help="local SHA256SUMS file (offline mode)")
    ap.add_argument("--dir", help="folder with the release files (sizes; checksums too if no --sums)")
    ap.add_argument("--date", help="release date YYYY-MM-DD (default: GitHub publish date / today)")
    ap.add_argument("--allow-draft", action="store_true")
    ap.add_argument("--mac-signed", action="store_true", help="the .dmg is Developer ID signed + notarized")
    ap.add_argument("--dry-run", action="store_true", help="print the result, write nothing")
    a = ap.parse_args()

    m = re.fullmatch(r"v(\d+\.\d+\.\d+)", a.tag)
    if not m:
        sys.exit("--tag must look like v1.2.3")
    version = m.group(1)

    if a.sums or a.dir:
        sizes, sums, date = from_local(a.sums, a.dir)
    else:
        sizes, sums, date = from_github(a.tag, a.repo, a.allow_draft)
    date = a.date or date

    data = json.loads(RELEASES.read_text(encoding="utf-8"))
    data["version"] = version
    data["date"] = date
    base = data["baseUrl"].replace("{version}", version)
    found, missing = 0, []
    for f in all_files(data):
        name = f["file"].replace("{version}", version)
        for k in ("url", "sha256", "size", "bytes"):
            f.pop(k, None)
        if name in sums and (name in sizes or not sizes):
            f["url"] = base + name
            f["sha256"] = sums[name]
            if name in sizes:
                f["bytes"] = sizes[name]
                f["size"] = human(sizes[name])
            f["available"] = True
            found += 1
        else:
            f["available"] = False
            missing.append(name)
        if f.get("id") == "mac-dmg":
            f["signed"] = bool(a.mac_signed)

    out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if a.dry_run:
        print(out)
    else:
        RELEASES.write_text(out, encoding="utf-8")
        sync_fallback(data)
    print(f"{found} file(s) available for v{version} ({date})", file=sys.stderr)
    for n in missing:
        print(f"  not in the release (kept unavailable): {n}", file=sys.stderr)
    if not found:
        sys.exit("no listed file was found in the release; nothing would be downloadable")


if __name__ == "__main__":
    main()
