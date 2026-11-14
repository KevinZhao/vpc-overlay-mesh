#!/usr/bin/env python3
"""pod 路由同步（T17）：以「权威路由表」（老 node 子网 RT，由 容器网络控制器写入 pod 段 → node ENI）为准，
1) 补齐 / 修正 transit 子网 RT（路由器解封装后经它投递到 node）里的同名路由；
2) 新出现的 pod 段放进新侧条目最少的 prefix list 分组（各组由不同路由器做入口）；已消失的 pod 段从 transit RT 和 PL 删除。
只处理 pod 地址池内、下一跳是非路由器 ENI 的路由。默认 dry-run，--apply 才写。
用法：podroute_sync.py --src-rt rtb-x --transit-rt rtb-y --pl pl-1 pl-2 pl-3 --pool 100.64.0.0/14 [--keep 100.64.10.0/24 ...] [--apply]"""
import argparse, ipaddress, json, time, boto3
ap = argparse.ArgumentParser()
ap.add_argument('--region', default='eu-central-1'); ap.add_argument('--src-rt', required=True); ap.add_argument('--transit-rt', required=True)
ap.add_argument('--pl', nargs='+', required=True); ap.add_argument('--pool', required=True)
ap.add_argument('--keep', nargs='*', default=[], help='权威 RT 之外、要保留在 PL 里的段（如实验里的固定 /26）')
ap.add_argument('--apply', action='store_true')
ap.add_argument('--max-delete', type=int, default=5, help='单次删除超过 N 条就中止（防止权威 RT 读到空表或部分结果时误删）')
ap.add_argument('--pl-role-arn', help='PL 在另一个账号时，assume 到该账号的角色（生产：PL 在新侧账号，transit RT 在老侧账号）')
ap.add_argument('--pl-region')
a = ap.parse_args()
ec2 = boto3.client('ec2', region_name=a.region); pool = ipaddress.ip_network(a.pool)
if a.pl_role_arn:
    cr = boto3.client('sts').assume_role(RoleArn=a.pl_role_arn, RoleSessionName='podroute-sync')['Credentials']
    ec2pl = boto3.client('ec2', region_name=a.pl_region or a.region, aws_access_key_id=cr['AccessKeyId'],
                         aws_secret_access_key=cr['SecretAccessKey'], aws_session_token=cr['SessionToken'])
else:
    ec2pl = ec2
routers = {e['NetworkInterfaceId'] for e in ec2.describe_network_interfaces(Filters=[{'Name': 'tag-key', 'Values': ['overlay-mesh']}])['NetworkInterfaces']}
def pod_routes(rt):
    out = {}
    for r in ec2.describe_route_tables(RouteTableIds=[rt])['RouteTables'][0]['Routes']:
        c = r.get('DestinationCidrBlock'); eni = r.get('NetworkInterfaceId')
        if c and eni and eni not in routers and ipaddress.ip_network(c).subnet_of(pool): out[c] = eni
    return out
t0 = time.time()
src = pod_routes(a.src_rt); tr = pod_routes(a.transit_rt)
if not src:
    raise SystemExit(json.dumps(dict(abort='权威 RT 里没有任何 pod 路由（读错表或 容器网络控制器正在重写）——不做任何修改')))
actions = []
for c, eni in src.items():
    if tr.get(c) != eni: actions.append(('transit-' + ('replace' if c in tr else 'create'), c, eni))
for c in tr:
    if c not in src: actions.append(('transit-delete', c, None))
TAG = 'pod (sync)'   # 只管理本工具加入的条目；其他条目（Terraform 写入的固定段、占位）一律不动（T17 教训）
pls = {}
for pl in a.pl:
    ents = ec2pl.get_managed_prefix_list_entries(PrefixListId=pl)['Entries']
    meta = ec2pl.describe_managed_prefix_lists(PrefixListIds=[pl])['PrefixLists'][0]
    pls[pl] = dict(max=meta['MaxEntries'], all={e['Cidr'] for e in ents}, managed={e['Cidr'] for e in ents if e.get('Description') == TAG}, add=[], remove=[])
in_pl = set().union(*[p['all'] for p in pls.values()])
for c in src:
    if c not in in_pl and c not in a.keep:
        tgt = min(pls, key=lambda p: len(pls[p]['all']) + len(pls[p]['add']))
        if len(pls[tgt]['all']) + len(pls[tgt]['add']) >= pls[tgt]['max']:
            raise SystemExit(json.dumps(dict(abort=f'所有 PL 都满了（{tgt} max={pls[tgt]["max"]}），需要扩容 PL 或新增路由器分组', pending=c)))
        pls[tgt]['add'].append(c); actions.append(('pl-add', c, tgt))
for pl, p in pls.items():
    for c in p['managed']:
        if c not in src: p['remove'].append(c); actions.append(('pl-remove', c, pl))
print(json.dumps(dict(src_pod_routes=len(src), transit_pod_routes=len(tr), actions=actions), ensure_ascii=False))
dels = [x for x in actions if x[0] in ('transit-delete', 'pl-remove')]
if a.apply and len(dels) > a.max_delete:
    raise SystemExit(json.dumps(dict(abort=f'本次要删除 {len(dels)} 条，超过 --max-delete={a.max_delete}，人工确认后加大该参数再执行')))
def wait_pl(pl, timeout=60):
    t = time.time()
    while time.time() - t < timeout:
        st = ec2pl.describe_managed_prefix_lists(PrefixListIds=[pl])['PrefixLists'][0]
        if st['State'] in ('modify-complete', 'create-complete'): return st['Version']
        if 'failed' in st['State']: raise RuntimeError(f"{pl} {st['State']} {st.get('StateMessage')}")
        time.sleep(0.5)
    raise TimeoutError(pl)
if a.apply:
    for act, c, x in actions:
        if act == 'transit-create': ec2.create_route(RouteTableId=a.transit_rt, DestinationCidrBlock=c, NetworkInterfaceId=x)
        elif act == 'transit-replace': ec2.replace_route(RouteTableId=a.transit_rt, DestinationCidrBlock=c, NetworkInterfaceId=x)
        elif act == 'transit-delete': ec2.delete_route(RouteTableId=a.transit_rt, DestinationCidrBlock=c)
    for pl, p in pls.items():            # 每个 PL 一次调用，带上当前版本；等 modify-complete 再处理下一个
        if not (p['add'] or p['remove']): continue
        v = wait_pl(pl)
        ec2pl.modify_managed_prefix_list(PrefixListId=pl, CurrentVersion=v,
            AddEntries=[{'Cidr': c, 'Description': TAG} for c in p['add']], RemoveEntries=[{'Cidr': c} for c in p['remove']])
        wait_pl(pl)
    print(json.dumps(dict(applied=len(actions), seconds=round(time.time() - t0, 2))))
