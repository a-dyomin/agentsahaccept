#!/usr/bin/env python3
from db import db, fetch_one

with db() as c:
    cur = c.execute(
        """
        UPDATE jobs j SET status='cancelled'
        FROM runs r
        WHERE j.run_id=r.id AND r.day::text=%s AND j.status='queued'
        """,
        ("2026-07-12",),
    )
    print("cancelled_12", cur.rowcount)
    cur = c.execute(
        """
        UPDATE runs SET status='done', finished_at=NOW()
        WHERE day::text=%s AND status='running'
        """,
        ("2026-07-12",),
    )
    print("runs_closed_12", cur.rowcount)
    c.commit()
    print(
        "q29",
        fetch_one(
            c,
            """
            SELECT COUNT(*) AS n FROM jobs j
            JOIN runs r ON r.id=j.run_id
            WHERE r.day::text=%s AND j.status='queued'
            """,
            ("2026-07-29",),
        ),
    )
    print(
        "q12",
        fetch_one(
            c,
            """
            SELECT COUNT(*) AS n FROM jobs j
            JOIN runs r ON r.id=j.run_id
            WHERE r.day::text=%s AND j.status='queued'
            """,
            ("2026-07-12",),
        ),
    )
