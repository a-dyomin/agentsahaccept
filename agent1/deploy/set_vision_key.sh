#!/bin/bash
# Set OpenAI/vision key into agent1 .env without printing it.
# Usage: bash set_vision_key.sh <api_key>
set -euo pipefail
KEY="${1:?api key}"
ENVF=/home/admin-akea/agent1/.env
touch "$ENVF"
chmod 600 "$ENVF"
python3 - <<PY
from pathlib import Path
p = Path("$ENVF")
key = """$KEY"""
vals = {
    "OPENAI_API_KEY": key,
    "AGENT1_VISION_API_KEY": key,
    "AGENT1_VISION_ENABLED": "auto",
    "AGENT1_VISION_MODEL": "gpt-4o-mini",
    "AGENT1_STAGE2": "1",
}
text = p.read_text() if p.exists() else ""
lines = text.splitlines()
seen = set()
out = []
for line in lines:
    if not line or line.startswith("#") or "=" not in line:
        out.append(line)
        continue
    k, _, _ = line.partition("=")
    if k in vals:
        out.append(f"{k}={vals[k]}")
        seen.add(k)
    else:
        out.append(line)
for k, v in vals.items():
    if k not in seen:
        out.append(f"{k}={v}")
p.write_text("\\n".join(out) + "\\n")
p.chmod(0o600)
print("vision_key_set", sorted(vals))
PY
