from pathlib import Path
import csv

base = Path(r"C:\Users\adyom\agentsahaccept\tz-repo") / "Выгрузки Гретты"
files = [
    "order_2026-07-14_11h18m20.csv",
    "photo_2026-07-14_13h49m59.csv",
    "report_site_2026-07-14_11h31m54.csv",
    "orders_12.07.26.csv",
    "fail_reason_2026-07-14_15h01m57.csv",
]

def detect(path: Path) -> str:
    raw = path.read_bytes()[:4000]
    for enc in ("utf-8-sig", "utf-8", "cp1251"):
        try:
            raw.decode(enc)
            return enc
        except UnicodeDecodeError:
            continue
    return "utf-8"

out = Path(r"C:\Users\adyom\agentsahaccept\outputs\_csv_headers.txt")
out.parent.mkdir(parents=True, exist_ok=True)
lines = []
for name in files:
    p = base / name
    enc = detect(p)
    with p.open("r", encoding=enc, newline="", errors="replace") as f:
        h = next(csv.reader(f))
    lines.append(f"=== {name} enc={enc} ===")
    for i, c in enumerate(h):
        lines.append(f"{i}: {c}")
    lines.append("")
out.write_text("\n".join(lines), encoding="utf-8")
print("wrote", out)
