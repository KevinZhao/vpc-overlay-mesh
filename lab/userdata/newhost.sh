#!/bin/bash
# 模拟新架构 VPC 内的服务（VPC IP）
set -euxo pipefail
dnf install -y iperf3 tcpdump >/var/log/poc-dnf.log 2>&1 || true
cat >/etc/systemd/system/iperf-srv.service <<'UNIT'
[Unit]
Description=iperf3 server
After=network-online.target
[Service]
ExecStart=/usr/bin/iperf3 -s
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now iperf-srv.service
