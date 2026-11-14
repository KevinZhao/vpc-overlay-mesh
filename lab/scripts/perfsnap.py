#!/usr/bin/env python3
"""路由器性能快照：网卡字节/包数、ENA allowance 计数、每 CPU softirq jiffies。输出一行 JSON。"""
import json, subprocess, time, os
snap = dict(t=time.time(), dev={}, ena={}, cpu={})
for d in os.listdir('/sys/class/net'):
    if d.startswith(('ens', 'vx-')):
        st = f'/sys/class/net/{d}/statistics/'
        snap['dev'][d] = {k: int(open(st + k).read()) for k in ('rx_bytes', 'tx_bytes', 'rx_packets', 'tx_packets', 'rx_dropped', 'tx_dropped')}
        if d.startswith('ens'):
            out = subprocess.run(['ethtool', '-S', d], capture_output=True, text=True).stdout
            snap['ena'][d] = {l.split(':')[0].strip(): int(l.split(':')[1]) for l in out.splitlines()
                              if 'allowance_exceeded' in l or l.strip().startswith(('rx_drops', 'tx_drops'))}
for l in open('/proc/stat'):
    f = l.split()
    if f[0].startswith('cpu') and f[0] != 'cpu':
        v = list(map(int, f[1:8])); snap['cpu'][f[0]] = dict(total=sum(v), idle=v[3] + v[4], softirq=v[6])
print(json.dumps(snap))
