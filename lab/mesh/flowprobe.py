#!/usr/bin/env python3
"""多流 UDP 探测：每条流一个源端口，按固定间隔发带序号的包，服务端回显；统计每条流的丢包区间。
server: flowprobe.py server [port] [ip1,ip2]
client: flowprobe.py client --src a,b --dst c,d --per 4 --interval 0.01 --duration 60 [--port 5300]
"""
import socket, struct, sys, time, select, argparse, json
if sys.argv[1] == 'server':
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5300
    ips = sys.argv[3].split(',') if len(sys.argv) > 3 else ['0.0.0.0']   # 每个地址单独绑定，保证回包源地址正确
    ss = []
    for ip in ips:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((ip, port)); ss.append(s)
    while True:
        for s in select.select(ss, [], [])[0]:
            d, a = s.recvfrom(64); s.sendto(d, a)
ap = argparse.ArgumentParser(); ap.add_argument('mode')
ap.add_argument('--src'); ap.add_argument('--dst'); ap.add_argument('--per', type=int, default=4)
ap.add_argument('--interval', type=float, default=0.01); ap.add_argument('--duration', type=float, default=60)
ap.add_argument('--port', type=int, default=5300)
a = ap.parse_args()
flows = []
for src in a.src.split(','):
    for dst in a.dst.split(','):
        for k in range(a.per):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((src, 0)); s.connect((dst, a.port)); s.setblocking(False)
            flows.append(dict(sock=s, src=src, dst=dst, sport=s.getsockname()[1], sent={}, got=set()))
socks = {f['sock'].fileno(): i for i, f in enumerate(flows)}
t0 = time.time(); n = int(a.duration / a.interval)
for seq in range(n):
    tick = t0 + seq * a.interval
    for i, f in enumerate(flows):
        f['sent'][seq] = time.time()
        try: f['sock'].send(struct.pack('!II', i, seq))
        except OSError: pass
    while True:
        to = tick + a.interval - time.time()
        if to <= 0: break
        r, _, _ = select.select([f['sock'] for f in flows], [], [], to)
        for s in r:
            try:
                while True:
                    d = s.recv(64); fi, sq = struct.unpack('!II', d); flows[fi]['got'].add(sq)
            except BlockingIOError: pass
time.sleep(1)
for f in flows:
    try:
        while True:
            d = f['sock'].recv(64); fi, sq = struct.unpack('!II', d); flows[fi]['got'].add(sq)
    except BlockingIOError: pass
out = []
for f in flows:
    runs = []; cur = None
    for sq in range(n):
        if sq not in f['got']:
            if cur and sq == cur[1] + 1: cur[1] = sq
            else:
                cur = [sq, sq]; runs.append(cur)
    big = [(round(f['sent'][x] , 3), round((y - x + 1) * a.interval, 2)) for x, y in runs if (y - x + 1) * a.interval >= 0.05]
    out.append(dict(src=f['src'], dst=f['dst'], sport=f['sport'], lost=n - len(f['got']), outages=big))
print(json.dumps(dict(t0=round(t0, 3), interval=a.interval, packets_per_flow=n, flows=out)))
