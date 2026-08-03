import socket

host = "192.168.111.59"
for port in (22, 80, 443, 8080, 3000, 8000, 2222, 22022, 34023, 22222):
    s = socket.socket()
    s.settimeout(5)
    try:
        s.connect((host, port))
        try:
            data = s.recv(256)
        except Exception:
            # send HTTP probe for web ports
            s.sendall(b"GET / HTTP/1.0\r\nHost: izhon.ru\r\n\r\n")
            data = s.recv(512)
        print(f"=== {port} ===")
        print(repr(data[:200]))
    except Exception as e:
        print(f"=== {port} FAIL {type(e).__name__}: {e}")
    finally:
        s.close()
