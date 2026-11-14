#!/usr/bin/env python3
"""L3 降级 / 恢复：
  down    先给入口路由表打 overlay-freeze=true（守护进程不再动这些表），等 3 s，再把全部入口路由并发改到 TGW
  restore 把入口路由并发改回各自 home 路由器的 ENI，再去掉 freeze 标签（之后由守护进程照常管理）
入口路由清单来自 mesh 配置（terraform output mesh_config）；home → ENI 从数据 ENI 的 overlay-name tag 查。
用法：fallback_tgw.py down|restore --config /tmp/ovr/mesh_config.json --tgw tgw-xxx [--sides a,b] [--profile <本侧账号>]
跨账号生产：两侧路由表在不同账号，**每个账号各执行一次**（--sides a --profile <老侧>；--sides b --profile <新侧>），
先降老侧还是新侧都可以（路径无状态，短时不对称不影响）；恢复时同样逐侧执行。"""
import argparse, json, time, concurrent.futures as cf, boto3
ap = argparse.ArgumentParser(); ap.add_argument('mode', choices=['down', 'restore'])
ap.add_argument('--config', required=True); ap.add_argument('--tgw', required=True); ap.add_argument('--sides', default='a,b')
ap.add_argument('--region', default='eu-central-1'); ap.add_argument('--profile')
a = ap.parse_args(); C = json.load(open(a.config))
ec2 = boto3.Session(profile_name=a.profile).client('ec2', region_name=a.region)
entries = [e for s in a.sides.split(',') for e in C['sides'][s]['entries']]
rts = sorted({e['rt'] for e in entries})
eni = {next(t['Value'] for t in n['TagSet'] if t['Key'] == 'overlay-name'): n['NetworkInterfaceId']
       for n in ec2.describe_network_interfaces(Filters=[{'Name': 'tag:overlay-mesh', 'Values': [C['mesh']]}])['NetworkInterfaces']}
def rep(e):
    kw = dict(RouteTableId=e['rt'])
    kw.update({'DestinationPrefixListId': e['pl']} if 'pl' in e else {'DestinationCidrBlock': e['cidr']})
    kw.update({'TransitGatewayId': a.tgw} if a.mode == 'down' else {'NetworkInterfaceId': eni[e['home']]})
    t = time.time(); ec2.replace_route(**kw); return (e.get('pl') or e['cidr'], round(time.time() - t, 2))
T0 = time.time()
if a.mode == 'down':
    ec2.create_tags(Resources=rts, Tags=[{'Key': 'overlay-freeze', 'Value': 'true'}]); time.sleep(3)
T1 = time.time()
with cf.ThreadPoolExecutor(32) as ex: res = list(ex.map(rep, entries))
T2 = time.time()
if a.mode == 'restore':
    ec2.delete_tags(Resources=rts, Tags=[{'Key': 'overlay-freeze'}])
print(json.dumps(dict(mode=a.mode, t_switch_start=round(T1, 3), switch_s=round(T2 - T1, 2), routes=res)))
