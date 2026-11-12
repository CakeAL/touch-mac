import socket, struct, time, sys
port = int(sys.argv[1]) if len(sys.argv) > 1 else 5288
s = socket.create_connection(("127.0.0.1", port), timeout=3)
def rec(t, i, x, y, f=0x07, p=0):
    s.sendall(struct.pack(">BBHHBB", t, i, int(x*65535), int(y*65535), f, p))
rec(1, 1, 0.3, 0.7); time.sleep(0.05)
for k in range(5):
    rec(2, 1, 0.30 + k*0.02, 0.70); time.sleep(0.02)
rec(3, 1, 0.38, 0.70); time.sleep(0.1)
# 双指
rec(1, 2, 0.5, 0.5); time.sleep(0.02)
rec(1, 3, 0.6, 0.5); time.sleep(0.02)
rec(2, 2, 0.45, 0.5); rec(2, 3, 0.65, 0.5); time.sleep(0.05)
rec(3, 2, 0.45, 0.5); rec(3, 3, 0.65, 0.5)
print("sent ok")
