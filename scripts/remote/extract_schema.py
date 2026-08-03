from pathlib import Path

p = Path("/home/gretaadmin/greta-backend/current/db/schema.rb")
text = p.read_text(encoding="utf-8", errors="replace")
for name in ["sites", "orders", "report_sites", "schedules"]:
    key = f'create_table "{name}"'
    i = text.find(key)
    print("====", name, "====")
    if i < 0:
        print("MISSING")
        continue
    j = text.find("\n  end\n", i)
    print(text[i : j + 6][:4000])
    print()
