import socket
s = socket.socket()
s.settimeout(5)
try:
    s.connect(("greta.akea-ds.ru", 34023))
    print("open")
    print(repr(s.recv(80)))
except Exception as e:
    print("fail", type(e).__name__, e)
finally:
    s.close()
