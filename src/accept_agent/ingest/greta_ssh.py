from __future__ import annotations

from dataclasses import dataclass

import paramiko

from accept_agent.config import Settings


@dataclass
class GretaSSH:
    client: paramiko.SSHClient

    def run(self, command: str, timeout: int = 60) -> tuple[int, str, str]:
        _stdin, stdout, stderr = self.client.exec_command(command, timeout=timeout)
        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        code = stdout.channel.recv_exit_status()
        return code, out, err

    def close(self) -> None:
        self.client.close()


def connect_greta(settings: Settings) -> GretaSSH:
    key_path = settings.ssh_key_path
    if not key_path.exists():
        raise FileNotFoundError(f"SSH key not found: {key_path}")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=settings.greta_ssh_host,
        port=settings.greta_ssh_port,
        username=settings.greta_ssh_user,
        key_filename=str(key_path),
        timeout=20,
        allow_agent=False,
        look_for_keys=False,
    )
    return GretaSSH(client=client)


def smoke_greta(settings: Settings) -> dict:
    ssh = connect_greta(settings)
    try:
        code, out, err = ssh.run("echo LOGIN_OK; whoami; hostname; pwd")
        return {
            "ok": code == 0 and "LOGIN_OK" in out,
            "exit_code": code,
            "stdout": out.strip(),
            "stderr": err.strip(),
            "host": settings.greta_ssh_host,
            "port": settings.greta_ssh_port,
            "user": settings.greta_ssh_user,
        }
    finally:
        ssh.close()
