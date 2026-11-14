#!/usr/bin/env python3
"""HTTP keep-alive 客户端探测：每个 (源, 目的) 组合 N 条长连接，每条每 interval 发一个 GET，超时 timeout。
失败（超时 / 连接错误）记一次并重连。输出：总请求、失败数、失败时间窗、延迟分布。
用法：httpprobe.py --src a,b --dst c,d --per 2 --interval 0.02 --timeout 1 --duration 60"""
import argparse, http.client, threading, time, json, socket
ap = argparse.ArgumentParser()
ap.add_argument('--src'); ap.add_argument('--dst'); ap.add_argument('--per', type=int, default=2)
ap.add_argument('--interval', type=float, default=0.02); ap.add_argument('--timeout', type=float, default=1.0)
ap.add_argument('--duration', type=float, default=60)
a = ap.parse_args()
res = []; lock = threading.Lock(); t_end = time.time() + a.duration
def worker(src, dst):
    conn = None; reqs = 0; errs = []; lat = []; reconnects = 0
    while time.time() < t_end:
        t0 = time.time()
        try:
            if conn is None:
                conn = http.client.HTTPConnection(dst, 80, timeout=a.timeout, source_address=(src, 0)); reconnects += 1
            conn.request('GET', '/', headers={'Connection': 'keep-alive'}); r = conn.getresponse(); r.read()
            lat.append(time.time() - t0)
        except Exception as e:
            errs.append((round(t0, 3), type(e).__name__)); 
            try: conn.close()
            except Exception: pass
            conn = None
        reqs += 1
        time.sleep(max(0, a.interval - (time.time() - t0)))
    lat.sort()
    with lock: res.append(dict(src=src, dst=dst, reqs=reqs, errors=errs, reconnects=reconnects - 1,
                               p50_ms=round(lat[len(lat)//2]*1000, 2) if lat else None,
                               p99_ms=round(lat[int(len(lat)*0.99)]*1000, 2) if lat else None,
                               max_ms=round(lat[-1]*1000, 1) if lat else None))
ths = [threading.Thread(target=worker, args=(s, d)) for s in a.src.split(',') for d in a.dst.split(',') for _ in range(a.per)]
for t in ths: t.start()
for t in ths: t.join()
print(json.dumps(res))
