#!/usr/bin/env python3
"""SSH into izhon host and print OS / web stack overview."""
from __future__ import annotations

import os
import sys

import paramiko

HOST = os.environ.get("IZHON_HOST", "192.168.111.59")
USER = os.environ.get("IZHON_USER", "admin-akea")
PASSWORD = os.environ.get("IZHON_PASSWORD", "")
PORT = int(os.environ.get("IZHON_SSH_PORT", "22"))

CMDS = [
    "uname -a; whoami; hostname",
    "command -v docker; command -v nginx; command -v caddy; command -v apache2; command -v node; command -v python3",
    "ls /etc/nginx/sites-enabled 2>/dev/null; ls /etc/nginx/conf.d 2>/dev/null; ls /etc/caddy 2>/dev/null",
    "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null | head -40",
    "ss -tlnp 2>/dev/null | head -40 || netstat -tlnp 2>/dev/null | head -40",
    "ls /var/www 2>/dev/null; ls /home 2>/dev/null; ls /opt 2>/dev/null",
    "grep -R \"izhon\" /etc/nginx 2>/dev/null | head -40",
]


def main() -> int:
    if not PASSWORD:
        print("Set IZHON_PASSWORD", file=sys.stderr)
        return 2
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, port=PORT, username=USER, password=PASSWORD, timeout=20)
    for cmd in CMDS:
        print(f"\n===== {cmd} =====")
        stdin, stdout, stderr = client.exec_command(cmd, timeout=60)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        if out:
            print(out.rstrip())
        if err:
            print("STDERR:", err.rstrip())
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
