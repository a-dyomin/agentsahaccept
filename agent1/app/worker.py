"""Shadow worker: Stage1 + Stage2 (S3 cache / optional vision) + ИТОГ merge."""
from __future__ import annotations

import os
import time
from typing import Any

import httpx

from stage1_shadow import decide_stage1
from stage2 import run_stage2

API = os.environ.get("AGENT1_API", "http://127.0.0.1:8101").rstrip("/")
WORKER_ID = os.environ.get("AGENT1_WORKER_ID", "worker-1")
POLL_SEC = float(os.environ.get("AGENT1_POLL_SEC", "0.5"))
STAGE2_ENABLED = os.environ.get("AGENT1_STAGE2", "1").lower() not in {"0", "false", "no"}


def process_job(payload: dict[str, Any]) -> dict[str, Any]:
    kind = payload.get("kind") or "stage1_shadow"
    if kind not in {"stage1_shadow", "stage1", "stage1_stage2"}:
        return {
            "agent_verdict": "К ЧЕЛОВЕКУ",
            "agent_detail": {"error": f"unknown_kind:{kind}"},
            "human_verdict": payload.get("human_breach_state"),
            "error": f"unknown_kind:{kind}",
        }

    stage2 = None
    if STAGE2_ENABLED:
        photos = payload.get("photos") or []
        stage2 = run_stage2(payload, photos)
    return decide_stage1(payload, stage2)


def loop() -> None:
    print(f"worker {WORKER_ID} -> {API} stage2={STAGE2_ENABLED}", flush=True)
    with httpx.Client(timeout=180.0) as client:
        while True:
            try:
                r = client.get(f"{API}/api/jobs/next", params={"worker_id": WORKER_ID})
                r.raise_for_status()
                job = (r.json() or {}).get("job")
                if not job:
                    time.sleep(POLL_SEC)
                    continue
                try:
                    result = process_job(job.get("payload") or {})
                    pr = client.post(f"{API}/api/jobs/{job['id']}/result", json=result)
                    pr.raise_for_status()
                    print(
                        f"done order={job['order_id']} verdict={result.get('agent_verdict')}",
                        flush=True,
                    )
                except Exception as exc:  # noqa: BLE001
                    client.post(
                        f"{API}/api/jobs/{job['id']}/result",
                        json={
                            "agent_verdict": "К ЧЕЛОВЕКУ",
                            "agent_detail": {},
                            "error": str(exc),
                        },
                    )
                    print(f"error order={job['order_id']}: {exc}", flush=True)
            except Exception as exc:  # noqa: BLE001
                print(f"poll error: {exc}", flush=True)
                time.sleep(2.0)


if __name__ == "__main__":
    loop()
