#!/usr/bin/env python3
"""T11：入口路由规模 vs ReplaceRoute 限流。在一张未关联子网的空路由表里建 N 条 /24 路由（下一跳 ENI-X），
然后并发把 N 条全部 replace 到 ENI-Y，记录总耗时、被限流次数；最后删除这些路由。
用法：t11_route_scale.py <rtb> <eni-from> <eni-to> [N=150]"""
import sys, time, json, concurrent.futures as cf, boto3, botocore
rt, ef, et = sys.argv[1:4]; N = int(sys.argv[4]) if len(sys.argv) > 4 else 150
ec2 = boto3.client('ec2', region_name='eu-central-1', config=botocore.config.Config(retries={'max_attempts': 1}, max_pool_connections=64))
cidrs = [f"100.80.{i}.0/24" for i in range(N)]
def call(fn, **kw):
    thr = 0
    while True:
        try: fn(**kw); return thr
        except botocore.exceptions.ClientError as e:
            if e.response['Error']['Code'] in ('RequestLimitExceeded', 'Throttling'): thr += 1; time.sleep(0.2); continue
            raise
def run(fn, items, **fixed):
    t = time.time(); done = []
    with cf.ThreadPoolExecutor(32) as ex:
        futs = {ex.submit(call, fn, DestinationCidrBlock=c, **fixed): c for c in items}
        for f in cf.as_completed(futs): done.append((time.time() - t, f.result()))
    d = sorted(x for x, _ in done)
    return dict(total_s=round(time.time() - t, 2), p50_s=round(d[len(d)//2], 2), at_50=round(d[min(49, len(d)-1)], 2),
                throttled=sum(r for _, r in done))
r1 = run(ec2.create_route, cidrs, RouteTableId=rt, NetworkInterfaceId=ef)
time.sleep(15)   # 让令牌桶回满
r2 = run(ec2.replace_route, cidrs, RouteTableId=rt, NetworkInterfaceId=et)
time.sleep(15)
r3 = run(ec2.delete_route, cidrs, RouteTableId=rt)
print(json.dumps(dict(N=N, create=r1, replace=r2, delete=r3), ensure_ascii=False))
