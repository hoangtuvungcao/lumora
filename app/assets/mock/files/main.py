"""Đồng bộ ảnh từ điện thoại sang máy tính qua Lumora."""
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

CHUNK = 256 * 1024  # 256 KB mỗi lần đọc


@dataclass
class Photo:
    path: Path
    size: int
    digest: str


def fingerprint(path: Path) -> str:
    """Băm BLAKE2 để bỏ qua ảnh đã có."""
    h = hashlib.blake2b(digest_size=16)
    with path.open("rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def scan(folder: Path) -> list[Photo]:
    exts = {".jpg", ".jpeg", ".png", ".heic"}
    photos = []
    for p in sorted(folder.rglob("*")):
        if p.suffix.lower() in exts:
            photos.append(Photo(p, p.stat().st_size, fingerprint(p)))
    return photos


def main() -> None:
    album = Path.home() / "Pictures" / "Đà Lạt 2026"
    photos = scan(album)
    total = sum(p.size for p in photos) / 1e6
    print(f"Tìm thấy {len(photos)} ảnh ({total:.1f} MB)")
    manifest = {p.digest: p.path.name for p in photos}
    Path("manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
