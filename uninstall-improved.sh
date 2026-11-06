#!/bin/bash
set -euo pipefail
red='\033[1;91m'; NC='\033[0m'
red() { echo -e "${red}$1${NC}"; }

systemctl disable --now xray 2>/dev/null || true
rm -f /etc/systemd/system/xray.service
systemctl daemon-reload 2>/dev/null || true

rc-service xray stop 2>/dev/null || true
rc-update del xray default 2>/dev/null || true
rm -f /etc/init.d/xray

pkill -9 -f xray 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true

rm -rf /etc/xray
rm -f /usr/local/etc/xray/config.json 2>/dev/null || true

echo -e "\033[1;32mXray 及相关组件已卸载完成。\033[0m"
