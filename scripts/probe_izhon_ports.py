import socket
import sys

host = "192.168.111.59"
for port in (22, 80, 443, 8080, 3000, 8000):
    s = socket.socket()
    s.settimeout(3)
    try:
        s.connect((host, port))
        print(f"port {port}: open")
    except Exception as e:
        print(f"port {port}: closed ({type(e).__name__})")
    finally:
        s.close()
