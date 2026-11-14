#!/usr/bin/env python3
"""路线二路由器守护进程 v4：全 active mesh + 自治切换 + 基于 ENI tag 的成员自动发现

身份与成员
- 数据 ENI 打 tag：overlay-mesh=<mesh>、overlay-side=a|b、overlay-name、overlay-index=<1..9>；
- IMDS 取本机 instance-id → 找到本机挂载的数据 ENI → 确定身份；每 DISCOVER 秒 DescribeNetworkInterfaces；
- v4：成员移除要连续 MISS_LIMIT 次查询都不在（防抖）；对侧成员突然变成 0 时忽略（防止一次空结果拆光隧道）。
  跨账号时对侧成员不可见，用配置里的 static_peers（{name, ip, idx}）补足。

数据面：每个对端一条 VXLAN（VNI = 100 + 10×A 序号 + B 序号）；隧道网段走 Linux 多路径；blackhole 兜底；
       所有对端同时失联时 fail-static；本进程装的路由都打 proto 199，不在期望集合里的自动删除。

健康
- 隧道探测 + 同侧直接探测（UDP 3784/3785）；回包附带：我看到的对侧存活集合、配置哈希。
- 判定同侧 X 故障：直接探测超时，且新鲜视图里多数票说 X 已失联（≥1 票）；看到的对端不足一半 → ISOLATED，不做入口决策。
- 自检（fail-closed，不通过就停止应答探测）：ip_forward=1、隧道设备齐全、依赖与 MSS 规则在位、FORWARD 链无 DROP/REJECT、
  数据 ENI 的 source/dest check 已关闭、各线程心跳正常、没有 drain 文件。

入口
- 只处理下一跳是「本侧路由器 ENI」的路由；指向 TGW / 其他目标或已被删除的路由视为人工操作，不动（v4）。
- home 故障 → 存活同侧路由器按 rendezvous hash 选接管者，只改下一跳是故障路由器 ENI 的路由。
- 收回（failback）要求：自检健康满 HOLD 秒，并且多数隧道对端的视图里持续看到自己满 HOLD 秒（v4，防单向可达互抢）；
  同侧配置哈希不一致时只接管、不收回。每条路由 MIN_MOVE 秒内最多切一次，频繁切换（60 s 内 ≥ 3 次）退避到 60 s。
- 路由表打 overlay-freeze=true 时整张表不动。
"""
import json, os, socket, subprocess, threading, time, struct, hashlib, ipaddress, urllib.request
import concurrent.futures as cf
C = json.load(open('/etc/overlay-mesh.json'))
CFG_HASH = hashlib.sha1(json.dumps(C, sort_keys=True).encode()).hexdigest()[:8]
INTERVAL = C.get('interval', 0.3); DETECT = C.get('detect', 0.9); HOLD = C.get('hold', 10); DISCOVER = C.get('discover', 10)
MISS_LIMIT = C.get('miss_limit', 3); MIN_MOVE = C.get('min_move', 10)
LOG = open('/var/log/overlay-mesh.log', 'a', buffering=1)
mono = time.monotonic
def log(*a):
    try: LOG.write(f"{time.time():.3f} " + " ".join(map(str, a)) + "\n")
    except OSError: pass                                   # 磁盘满等不得打死进程（v4）
def sh(cmd): return subprocess.run(cmd, shell=True, capture_output=True, text=True)

import boto3, botocore
ec2 = boto3.client('ec2', region_name=C['region'], config=botocore.config.Config(
    retries={'max_attempts': 1}, connect_timeout=1, read_timeout=2))

def imds(path):
    tok = urllib.request.urlopen(urllib.request.Request('http://169.254.169.254/latest/api/token', method='PUT',
          headers={'X-aws-ec2-metadata-token-ttl-seconds': '300'}), timeout=2).read().decode()
    return urllib.request.urlopen(urllib.request.Request('http://169.254.169.254/latest/meta-data/' + path,
          headers={'X-aws-ec2-metadata-token': tok}), timeout=2).read().decode()

# ---------- 共享状态（lock 保护） ----------
lock = threading.RLock()
ME = None; MY_ENI = None; MY_IP = None; SIDE_KEY = None; SCFG = None; MY_SDC = None
PEERS = []; SIDE = []; ENI_OWNER = {}; TUN2NAME = {}; SIDE_IP2NAME = {}
tun_rx = {}; side_rx = {}; views = {}; side_hash = {}; tun_alive = set(); last_nh = set()
tun_ok = {}; side_ok = {}; side_tc = {}; tun_reach = set()   # v4.1：可达性（回包到达）与可用性（对方健康）分开
healthy = False; healthy_since = None; seen_since = None
rt_cache = {}; rt_frozen = set(); inflight = {}; moves = {}
miss = {}; beats = {}; ALL_ENI = {}; iso_since = None; noniso_since = None
def beat(name): beats[name] = mono()

def tags(e): return {t['Key']: t['Value'] for t in e.get('TagSet', [])}

def discover():
    r = ec2.describe_network_interfaces(Filters=[{'Name': 'tag:overlay-mesh', 'Values': [C['mesh']]}])['NetworkInterfaces']
    mem = []; alleni = {}
    for e in r:
        t = tags(e); att = e.get('Attachment') or {}
        if 'overlay-name' in t and 'overlay-side' in t: alleni[e['NetworkInterfaceId']] = (t['overlay-side'], t['overlay-name'])
        if att.get('Status') != 'attached': continue
        try:
            mem.append(dict(name=t['overlay-name'], side=t['overlay-side'], idx=int(t['overlay-index']), ip=e['PrivateIpAddress'],
                            eni=e['NetworkInterfaceId'], instance=att.get('InstanceId'), sdc=e.get('SourceDestCheck')))
        except (KeyError, ValueError): log("WARN tag 不全，忽略", e['NetworkInterfaceId'])
    me = next((m for m in mem if m['instance'] == INSTANCE), None)
    if me:   # 跨账号：对侧成员走配置
        other = 'b' if me['side'] == 'a' else 'a'
        known = {m['name'] for m in mem}
        for s in C.get('static_peers', {}).get(other, []):
            if s['name'] not in known: mem.append(dict(s, side=other, eni=None, instance=None, sdc=False))
        ALL_ENI.update({k: v for k, v in alleni.items()})
    return me, mem

def apply_members(me, mem):
    global ME, MY_ENI, MY_IP, SIDE_KEY, SCFG, MY_SDC, PEERS, SIDE, ENI_OWNER, TUN2NAME, SIDE_IP2NAME
    other = 'b' if me['side'] == 'a' else 'a'
    seen = {m['name'] for m in mem}
    with lock:
        # 防抖：已有成员要连续 MISS_LIMIT 次不在才移除；对侧突然变 0 时整体忽略
        cur_other = [m for m in mem if m['side'] == other]
        if PEERS and not cur_other:
            log("WARN 发现结果里对侧成员为 0，忽略本次（保留现有隧道）"); return
        keep = []
        for p in PEERS + [dict(s, side=me['side']) for s in SIDE]:
            if p['name'] in seen: miss.pop(p['name'], None); continue
            miss[p['name']] = miss.get(p['name'], 0) + 1
            if miss[p['name']] < MISS_LIMIT: keep.append(p)
            else: log("MEMBER-GONE", p['name'], f"连续 {MISS_LIMIT} 次未发现")
        for k in keep:
            mem.append(dict(name=k['name'], side=k.get('side', other), idx=k['idx'], ip=k['ip'], eni=k.get('eni'), instance=None, sdc=False))
        peers = []
        for m in sorted((m for m in mem if m['side'] == other), key=lambda m: m['idx']):
            ia, ib = (me['idx'], m['idx']) if me['side'] == 'a' else (m['idx'], me['idx'])
            vni = 100 + 10 * ia + ib; net = f"169.254.{vni}"
            loc, rem = (f"{net}.1", f"{net}.2") if me['side'] == 'a' else (f"{net}.2", f"{net}.1")
            peers.append(dict(name=m['name'], idx=m['idx'], dev=f"vx-{m['name'].lower()}", ip=m['ip'], vni=vni,
                              tun_local=f"{loc}/30", tun_peer=rem))
        side = [dict(name=m['name'], idx=m['idx'], ip=m['ip'], eni=m.get('eni')) for m in mem
                if m['side'] == me['side'] and m['name'] != me['name']]
        changed = (ME is None or [(p['name'], p['ip']) for p in peers] != [(p['name'], p['ip']) for p in PEERS]
                   or {s['name'] for s in side} != {s['name'] for s in SIDE})
        old_devs = {p['dev'] for p in PEERS}
        ME, MY_ENI, MY_IP, SIDE_KEY, MY_SDC = me['name'], me['eni'], me['ip'], me['side'], me.get('sdc')
        SCFG = C['sides'][SIDE_KEY]
        PEERS, SIDE = peers, side
        # 本侧所有带 tag 的 ENI（含已卸载的）都算路由器 ENI：卸载后指向它的路由仍可被接管（v4）
        ENI_OWNER = {eni: n for eni, (sd, n) in ALL_ENI.items() if sd == me['side']}
        ENI_OWNER.update({m['eni']: m['name'] for m in mem if m['side'] == me['side'] and m.get('eni')})
        TUN2NAME = {p['tun_peer']: p['name'] for p in peers}; SIDE_IP2NAME = {s['ip']: s['name'] for s in side}
        for p in peers: tun_rx.setdefault(p['name'], -1e9)
        for s in side: side_rx.setdefault(s['name'], -1e9)
        names = {p['name'] for p in peers}
        for n in list(tun_rx):
            if n not in names: tun_rx.pop(n, None); views.pop(n, None)
        for d in old_devs - {p['dev'] for p in peers}: sh(f"ip link del {d}"); log("REMOVE", d)
    if changed:
        log("MEMBERS", f"me={ME}({SIDE_KEY},{MY_IP})", "peers=" + ",".join(p['name'] for p in peers),
            "side=" + ",".join(s['name'] for s in side), f"cfg={CFG_HASH}")

def discoverer():
    while True:
        beat('discoverer')
        try:
            me, mem = discover()
            if me: apply_members(me, mem)
            else: log("WARN 本机没有挂载带 tag 的数据 ENI")
        except Exception as e: log("ERR discover", str(e)[:200])
        time.sleep(DISCOVER)

# ---------- 数据面 ----------
PROTO = 199
def data_dev():
    for l in sh("ip -o -4 addr show").stdout.splitlines():
        f = l.split()
        if MY_IP and f[3].split('/')[0] == MY_IP: return f[1], f[3]
    return None, None

def apply_routes(cur):
    global last_nh
    use = cur if cur else last_nh
    if not cur and last_nh: log("FAILSTATIC keep=" + ",".join(sorted(last_nh)))
    if cur: last_nh = set(cur)
    nh = " ".join(f"nexthop via {p['tun_peer']} dev {p['dev']} weight 1" for p in PEERS if p['name'] in use)
    for c in SCFG['tunnel_cidrs']:
        if nh:
            r = sh(f"ip route replace {c} proto {PROTO} {nh}")
            if r.returncode: log("ERR route", c, r.stderr.strip())

def cleanup_stale(peers):
    want = {(str(ipaddress.ip_network(c)), m) for c in SCFG['tunnel_cidrs'] for m in ('0', '32000')}
    want |= {(str(ipaddress.ip_network(c)), '0') for c in SCFG['eth_cidrs']}
    want |= {(f"{p['ip']}/32", '0') for p in peers}
    for l in sh(f"ip -o route show proto {PROTO}").stdout.splitlines():
        f = l.split(); dst = f[1] if f[0] in ('blackhole', 'unreachable') else f[0]
        net = str(ipaddress.ip_network(dst if '/' in dst else dst + '/32'))
        metric = f[f.index('metric') + 1] if 'metric' in f else '0'
        if (net, metric) not in want:
            sh(f"ip route del {'blackhole ' if f[0] == 'blackhole' else ''}{dst} metric {metric} proto {PROTO}"); log("STALE removed", l[:120])

def reconcile():
    dev, cidr = data_dev()
    if not dev: return
    gw = str(ipaddress.ip_interface(cidr).network.network_address + 1)
    sh(f"sysctl -qw net.ipv4.fib_multipath_hash_policy=1 net.ipv4.conf.{dev}.rp_filter=0")
    with lock: peers = list(PEERS)
    for p in peers:
        info = sh(f"ip -d -j link show {p['dev']}").stdout
        ok = False
        try:
            d = json.loads(info)[0]['linkinfo']['info_data']
            ok = d.get('id') == p['vni'] and d.get('remote') == p['ip'] and d.get('local') == MY_IP
        except Exception: pass
        if not ok:
            sh(f"ip link del {p['dev']}")
            r = sh(f"ip link add {p['dev']} type vxlan id {p['vni']} local {MY_IP} remote {p['ip']} "
                   f"dstport 4789 srcport 32768 61000 nolearning dev {dev}")
            log("CREATE", p['dev'], r.stderr.strip())
        sh(f"ip link set {p['dev']} mtu 8951 up; ip addr replace {p['tun_local']} dev {p['dev']}; "
           f"sysctl -qw net.ipv4.conf.{p['dev']}.rp_filter=0")
        sh(f"ip route replace {p['ip']}/32 via {gw} dev {dev} onlink proto {PROTO}")
    for c in SCFG['eth_cidrs']:
        sh(f"ip route replace {c} via {gw} dev {dev} onlink proto {PROTO}")
    for c in SCFG['tunnel_cidrs']:
        sh(f"ip route replace blackhole {c} metric 32000 proto {PROTO}")
    cleanup_stale(peers)
    if sh("iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu").returncode:
        sh("iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu")
    with lock: apply_routes(tun_alive)

def reconciler():
    while True:
        beat('reconciler')
        if ME:
            try: reconcile()
            except Exception as e: log("ERR reconcile", str(e)[:200])
        time.sleep(1)

_chk = dict(t=-1e9, ok=False, why='init'); _was_iso = False; _warned = {}
def slow_checks():
    """每秒最多一次的检查：依赖、MSS、FORWARD 链、source/dest check（v4：转发面静默故障）"""
    if mono() - _chk['t'] < 1: return _chk['ok'], _chk['why']
    why = ''
    if not all(os.path.exists(x) for x in ('/usr/sbin/iptables', '/usr/sbin/ethtool')): why = 'deps'
    elif sh("iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu").returncode: why = 'mss'
    else:
        fw = sh("iptables -S FORWARD").stdout
        if '-P FORWARD DROP' in fw or ' -j DROP' in fw or ' -j REJECT' in fw: why = 'forward-drop'
        elif MY_SDC is True: why = 'source-dest-check-on'
        else:
            dev, _ = data_dev()
            try: st = open(f'/sys/class/net/{dev}/operstate').read().strip() if dev else 'missing'
            except OSError: st = 'missing'
            if st != 'up': why = f'data-dev-{st}'
    _chk.update(t=mono(), ok=(why == ''), why=why)
    return _chk['ok'], why

def self_check():
    try: fwd = open('/proc/sys/net/ipv4/ip_forward').read().strip() == '1'
    except OSError: fwd = False
    if not ME: return False, 'no-identity'
    if not fwd: return False, 'ip_forward'
    if not all(os.path.exists(f"/sys/class/net/{p['dev']}") for p in PEERS): return False, 'tunnel-dev'
    if os.path.exists('/etc/overlay-mesh.drain'): return False, 'drain'
    now = mono()
    # 持续隔离（看不到一半以上对端）超过 2×DETECT → 判自己不健康，让同伴接管我的入口；连续 3 s 不隔离才恢复（v4）
    if iso_since is not None and now - iso_since > 2 * DETECT: return False, 'isolated'
    if not healthy and _was_iso and (noniso_since is None or now - noniso_since < 3): return False, 'isolated-recovering'
    for n, lim in (('responder', 3), ('reconciler', 5), ('entry', 3)):        # 数据面相关的线程卡住 → 不健康
        if now - beats.get(n, now) > lim: return False, f'thread-{n}'
    # 调 EC2 API 的线程（discoverer / refresher）卡住只影响入口决策，不影响转发：只告警，不判不健康（v4.2，T16 发现）
    for n, lim in (('discoverer', DISCOVER + 30), ('refresher', 30)):
        if now - beats.get(n, now) > lim and _warned.get(n, 0) < now - 60: log("WARN", f"thread-{n} 超过 {lim}s 未更新（多半是 EC2 API 慢或不可用）"); _warned[n] = now
    return slow_checks()

def responder():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 3784)); s.settimeout(1)
    while True:
        beat('responder')
        try:
            d, a = s.recvfrom(256)
            # v4.1：永远应答（不健康也应答，并带 ok=false）。v4 的「不健康就不应答」会造成全网互相看不见、无法恢复的级联锁死
            with lock: v = sorted(tun_alive); tc = len(tun_reach)
            s.sendto(d[:12] + json.dumps(dict(v=v, h=CFG_HASH, n=ME, ok=healthy, tc=tc)).encode(), a)
        except socket.timeout: pass
        except Exception as e: log("ERR responder", str(e)[:120])

# ---------- 入口控制 ----------
def quorum(n): return n // 2 + 1
def fresh_views(now):
    with lock: return {p: views[p][1] for p in tun_reach if p in views and now - views[p][0] < DETECT}

def side_alive(now):
    fv = list(fresh_views(now).values())
    res = {ME} if healthy else set()
    for x in SIDE:
        n = x['name']
        if now - side_rx.get(n, -1e9) < DETECT and side_ok.get(n, True): res.add(n); continue
        if now - side_rx.get(n, -1e9) < DETECT and not side_ok.get(n, True): continue     # 可达但自报不健康 → 视为故障
        dead = sum(1 for v in fv if n not in v)
        if not fv or dead < max(1, quorum(len(fv))): res.add(n)     # 新鲜视图里多数票判死；证据不足视为存活
    return res

def isolated(now):
    """v4.1：看到的对端不足一半，并且有同侧同伴看到的比我多 → 问题在我（过载 / 被单独隔离）。
    大家都看不到（pcx 断、对侧大面积故障）时不算隔离：谁都不下线，统一 fail-static，避免级联。"""
    with lock:
        n = len(PEERS); reach = len(tun_reach)
        sib = [side_tc[x['name']] for x in SIDE if now - side_rx.get(x['name'], -1e9) < DETECT and x['name'] in side_tc]
    if reach >= max(1, (n + 1) // 2): return False
    return (not sib) or max(sib) > reach

def seen_by_peers(now):
    fv = list(fresh_views(now).values())
    return bool(fv) and sum(1 for v in fv if ME in v) >= quorum(len(fv))

def ekey(e): return (e['rt'], e.get('cidr') or e.get('pl'))
def owner_of(e, alive):
    if e['home'] in alive: return e['home']
    if not alive: return None
    return max(alive, key=lambda n: hashlib.sha1(f"{ekey(e)[1]}|{n}".encode()).hexdigest())

def refresh_rt():
    global rt_cache, rt_frozen
    if not SCFG: return
    cache, fz = {}, set()
    for rtid in sorted({e['rt'] for e in SCFG['entries']}):     # v4：逐张查询，一张失效不影响其他
        try:
            rt = ec2.describe_route_tables(RouteTableIds=[rtid])['RouteTables'][0]
            for r in rt['Routes']:
                cache[(rtid, r.get('DestinationCidrBlock') or r.get('DestinationPrefixListId'))] = r.get('NetworkInterfaceId') or r.get('TransitGatewayId') or r.get('GatewayId') or 'other'
            if tags({'TagSet': rt.get('Tags', [])}).get('overlay-freeze') == 'true': fz.add(rtid)
        except Exception as e:
            log("ERR describe_rt", rtid, str(e)[:120]); fz.add(rtid)    # 查不到的表当作冻结，不做决策
            cache.update({k: v for k, v in rt_cache.items() if k[0] == rtid})
    if fz != rt_frozen: log("FREEZE", "frozen=" + ",".join(sorted(fz)))
    rt_cache, rt_frozen = cache, fz

def rt_refresher():
    while True:
        beat('refresher')
        try: refresh_rt()
        except Exception as e: log("ERR refresher", str(e)[:200])
        time.sleep(2)

pool = cf.ThreadPoolExecutor(16)
def can_move(k):
    now = mono(); h = [t for t in moves.get(k, []) if now - t < 60]; moves[k] = h
    gap = 60 if len(h) >= 3 else MIN_MOVE
    return not h or now - h[-1] >= gap

def replace(e, why):
    k = ekey(e)
    if inflight.get(k, 0) > mono() or not can_move(k): return
    inflight[k] = mono() + 30
    def run():
        t = mono()
        try:
            kw = dict(RouteTableId=e['rt'], NetworkInterfaceId=MY_ENI)
            if 'pl' in e: kw['DestinationPrefixListId'] = e['pl']
            else: kw['DestinationCidrBlock'] = e['cidr']
            ec2.replace_route(**kw)
            rt_cache[k] = MY_ENI; moves.setdefault(k, []).append(mono())
            log("TAKE", why, k[1], f"api={mono()-t:.3f}s"); inflight[k] = 0
        except Exception as ex:
            msg = str(ex)
            back = 30 if ('NotFound' in msg or 'InvalidRoute' in msg) else min(30, 0.5 * 2 ** len(moves.get(('err',) + k, [])))
            moves.setdefault(('err',) + k, []).append(mono())
            log("ERR replace", k[1], msg[:160], f"retry_in={back}s"); inflight[k] = mono() + back
    pool.submit(run)

def entry_controller():
    global seen_since
    last = None; iso_last = None; mm_last = None
    while True:
        beat('entry')
        try:
            if ME:
                now = mono(); alive = side_alive(now); iso = isolated(now)
                if alive != last: log("SIDE", "alive=" + ",".join(sorted(alive))); last = alive
                if iso != iso_last: log("ISOLATED" if iso else "QUORUM-OK"); iso_last = iso
                seen = seen_by_peers(now)
                if seen and seen_since is None: seen_since = now
                if not seen: seen_since = None
                with lock: mismatch = sorted(n for n, h in side_hash.items() if h != CFG_HASH and now - side_rx.get(n, -1e9) < DETECT)
                if mismatch != mm_last:
                    if mismatch: log("CONFIG-MISMATCH", ",".join(mismatch), "→ 只接管、不收回")
                    mm_last = mismatch
                if healthy and not iso:
                    for e in SCFG['entries']:
                        if e['rt'] in rt_frozen: continue
                        cur = rt_cache.get(ekey(e))
                        if cur == MY_ENI or cur not in ENI_OWNER: continue   # v4：非本侧路由器的目标 = 人工操作，不碰
                        if owner_of(e, alive) != ME: continue
                        cur_owner = ENI_OWNER.get(cur)
                        if e['home'] == ME:
                            if (not mismatch and healthy_since and now - healthy_since >= HOLD
                                    and seen_since and now - seen_since >= HOLD):
                                replace(e, "failback")
                        elif cur_owner not in alive:
                            replace(e, f"takeover-from-{cur_owner}")
        except Exception as e: log("ERR entry", repr(e)[:200])
        time.sleep(0.05)

# ---------- 探测 ----------
def prober():
    global tun_alive, healthy, healthy_since, tun_reach
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('0.0.0.0', 3785)); s.setblocking(False)
    seq = 0; why_last = None
    while True:
        try:
            global iso_since, noniso_since, _was_iso
            t = mono(); seq += 1
            if ME:
                iso = isolated(t)
                if iso: noniso_since = None; iso_since = iso_since if iso_since is not None else t
                else: iso_since = None; noniso_since = noniso_since if noniso_since is not None else t
            h, why = self_check()
            if why == 'isolated': _was_iso = True
            elif h: _was_iso = False
            if h != healthy or (not h and why != why_last):
                if h != healthy: healthy_since = t if h else None
                healthy = h; log("SELF", "healthy" if h else f"UNHEALTHY reason={why}"); why_last = why
            with lock: targets = [p['tun_peer'] for p in PEERS] + [x['ip'] for x in SIDE]
            pkt = struct.pack('!Id', seq, time.time())
            for ip in targets:
                try: s.sendto(pkt, (ip, 3784))
                except OSError: pass
            end = t + INTERVAL
            while mono() < end:
                try:
                    d, a = s.recvfrom(256); now = mono()
                    try: info = json.loads(d[12:] or b'{}')
                    except ValueError: info = {}
                    if isinstance(info, list): info = {'v': info}     # 兼容 v3 回包（滚动升级期间新旧版本共存）
                    elif not isinstance(info, dict): info = {}
                    with lock:
                        if a[0] in TUN2NAME:
                            n = TUN2NAME[a[0]]; tun_rx[n] = now; views[n] = (now, set(info.get('v', [])))
                            tun_ok[n] = info.get('ok', True)
                        elif a[0] in SIDE_IP2NAME:
                            n = SIDE_IP2NAME[a[0]]; side_rx[n] = now; side_hash[n] = info.get('h')
                            side_ok[n] = info.get('ok', True); side_tc[n] = info.get('tc', 99)
                except BlockingIOError: time.sleep(0.005)
            now = mono()
            with lock:
                tun_reach = {n for n, ts in tun_rx.items() if now - ts < DETECT}
                cur = {n for n in tun_reach if tun_ok.get(n, True)}
                if cur != tun_alive:
                    log("TUN", "up=" + ",".join(sorted(cur)), "down=" + ",".join(sorted(set(tun_rx) - cur)))
                    tun_alive = cur
                    if SCFG: apply_routes(tun_alive)
        except Exception as e: log("ERR prober", repr(e)[:200]); time.sleep(0.1)

sh("sysctl -qw net.ipv4.ip_forward=1")
log("START", f"interval={INTERVAL} detect={DETECT} hold={HOLD} cfg={CFG_HASH}")
while True:
    try: INSTANCE = imds('instance-id'); break
    except Exception as e: log("WAIT IMDS", str(e)[:80]); time.sleep(2)
while ME is None:
    try:
        me, mem = discover()
        if me: apply_members(me, mem)
        else: log("WAIT 等待数据 ENI 挂载"); time.sleep(2)
    except Exception as e: log("ERR discover", str(e)[:200]); time.sleep(2)
for f in (responder, reconciler, entry_controller, discoverer, rt_refresher):
    threading.Thread(target=f, daemon=True).start()
prober()
