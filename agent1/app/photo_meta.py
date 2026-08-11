"""Photo helpers: shot time from filename, MIME sniff, EXIF transpose (TZ 04.08.2026)."""
from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from typing import Any

# JPEG_20260802_091712.jpg  /  IMG_20260802_091712
_RE_APP = re.compile(
    r"(?:JPEG|IMG|DSC)[_\-]?(\d{8})[_\-](\d{6})",
    re.IGNORECASE,
)
# 2026-08-02_21-38-29.png  /  20260802_213829
_RE_ALT = re.compile(
    r"(?:^|[_\-])(\d{4})[-_]?(\d{2})[-_]?(\d{2})[_-](\d{2})[-_]?(\d{2})[-_]?(\d{2})",
)


def shot_datetime_from_filename(name: str | None) -> datetime | None:
    """Parse capture time from Greta photo filename. DB «Время» is unreliable."""
    if not name:
        return None
    base = Path(str(name)).name
    m = _RE_APP.search(base)
    if m:
        try:
            return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
        except ValueError:
            pass
    m = _RE_ALT.search(base)
    if m:
        try:
            y, mo, d, h, mi, s = m.groups()
            return datetime(int(y), int(mo), int(d), int(h), int(mi), int(s))
        except ValueError:
            pass
    return None


def shot_time_label(name: str | None) -> str | None:
    dt = shot_datetime_from_filename(name)
    return dt.strftime("%H:%M:%S") if dt else None


def sniff_image_mime(data: bytes) -> str:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return "application/octet-stream"


def prepare_image_for_vision(path: Path) -> tuple[bytes, str]:
    """Apply EXIF orientation; return (bytes, mime) sniffing content (not extension)."""
    raw = path.read_bytes()
    mime = sniff_image_mime(raw)
    try:
        from io import BytesIO

        from PIL import Image, ImageOps

        img = Image.open(BytesIO(raw))
        img = ImageOps.exif_transpose(img)
        buf = BytesIO()
        fmt = "PNG" if mime == "image/png" else "JPEG"
        if fmt == "JPEG":
            if img.mode in ("RGBA", "P"):
                img = img.convert("RGB")
            img.save(buf, format="JPEG", quality=92)
            return buf.getvalue(), "image/jpeg"
        img.save(buf, format="PNG")
        return buf.getvalue(), "image/png"
    except Exception:  # noqa: BLE001
        if mime == "application/octet-stream":
            # extension fallback
            suf = path.suffix.lower()
            if suf == ".png":
                mime = "image/png"
            elif suf in {".jpg", ".jpeg"}:
                mime = "image/jpeg"
            else:
                mime = "image/jpeg"
        return raw, mime


def sort_photos_by_shot_time(photos: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Chronological order by filename time; unknown times last, stable by photo_id."""

    def key(ph: dict[str, Any]) -> tuple:
        fn = ph.get("filename") or ""
        dt = shot_datetime_from_filename(str(fn))
        ts = dt.timestamp() if dt else 1e18
        pid = ph.get("photo_id") or ph.get("id") or 0
        try:
            pid = int(pid)
        except (TypeError, ValueError):
            pid = 0
        return (ts, pid)

    return sorted(photos, key=key)
