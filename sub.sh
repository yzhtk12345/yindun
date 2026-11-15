#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Client Subscription Manager & Background Daemon (sub.sh)
# Description: 支持 VLESS-REALITY 与 Hysteria 2（SHA-256 指纹校验）的双端动态订阅服务
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
NODES_DB="${CONFIG_DIR}/all_nodes.txt"
PORT_RECORD_FILE="${CONFIG_DIR}/sub_web_port.txt"
PID_FILE="${CONFIG_DIR}/sub_server.pid"
PYTHON_SERVER_FILE="${CONFIG_DIR}/sub_server.py"
TOKEN_FILE="${CONFIG_DIR}/sub_token.txt"

mkdir -p "$CONFIG_DIR"

detect_firewall() {
    if systemctl is-active --quiet ufw 2>/dev/null || command -v ufw &>/dev/null; then
        echo "ufw"
    elif systemctl is-active --quiet firewalld 2>/dev/null || command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

cleanup_old_sub_firewall_rules() {
    local fw_type
    fw_type=$(detect_firewall)

    if [ -f "$PORT_RECORD_FILE" ]; then
        local old_port
        old_port=$(cat "$PORT_RECORD_FILE")
        if [[ -n "$old_port" ]]; then
            case "$fw_type" in
                ufw)
                    ufw delete allow "${old_port}/tcp" >/dev/null 2>&1
                    ufw reload >/dev/null 2>&1
                    ;;
                firewalld)
                    firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1
                    firewall-cmd --reload >/dev/null 2>&1
                    ;;
                iptables)
                    iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true
                    ;;
            esac
        fi
    fi
}

manage_firewall_port() {
    local action="$1"
    local port="$2"
    local comment="$3"
    local fw_type
    fw_type=$(detect_firewall)

    case "$fw_type" in
        ufw)
            if [[ "$action" == "add" ]]; then
                ufw allow "$port/tcp" comment "$comment" >/dev/null 2>&1
                ufw reload >/dev/null 2>&1
            fi
            ;;
        firewalld)
            if [[ "$action" == "add" ]]; then
                firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
            fi
            ;;
        iptables)
            if [[ "$action" == "add" ]]; then
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            fi
            ;;
    esac
}

check_port_used() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tuln | grep -q ":${port} " && return 0 || return 1
    else
        nc -z 127.0.0.1 "$port" &>/dev/null && return 0 || return 1
    fi
}

get_web_port() {
    local target_port=""
    
    if [ -f "$PORT_RECORD_FILE" ]; then
        target_port=$(cat "$PORT_RECORD_FILE")
        if [[ "$target_port" =~ ^[0-9]+$ ]] && [ "$target_port" -ge 10000 ] && [ "$target_port" -le 20000 ]; then
            echo -e "${CYAN}[INFO] 检测到已固化的订阅服务端口: ${target_port}${NC}" >&2
            read -p "是否需要重新生成随机端口和重置 Token？[y/N]: " reset_choice
            if [[ "$reset_choice" =~ ^[Yy]$ ]]; then
                cleanup_old_sub_firewall_rules
                rm -f "$PORT_RECORD_FILE"
                rm -f "$TOKEN_FILE"
                target_port=""
            fi
        fi
    fi

    if [ -z "$target_port" ]; then
        while true; do
            target_port=$((RANDOM % 10001 + 10000))
            if ! check_port_used "$target_port"; then
                break
            fi
        done
        echo "$target_port" > "$PORT_RECORD_FILE"
        echo -e "${GREEN}[INFO] 已为您新分配并固化订阅服务端口: ${target_port}${NC}" >&2
    fi

    echo "$target_port"
}

get_public_ip() {
    local ip=""
    for service in "https://api.ipify.org" "https://ip.sb" "https://icanhazip.com"; do
        ip=$(curl -s4 --max-time 3 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "45.207.156.146"
}

stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo -e "${GREEN}[INFO] 已停止旧的订阅后台服务 (PID: ${pid})${NC}"
        fi
        rm -f "$PID_FILE"
    fi
}

# 独立生成 sub_server.py 脚本，完美支持多协议动态订阅解析
prepare_python_server() {
    export YD_PYTHON_SERVER_FILE="$PYTHON_SERVER_FILE"
    python3 -c '
import os

server_code = r"""import http.server
import urllib.parse
import sys
import os
import json
import base64

port = int(sys.argv[1])
token = sys.argv[2]
config_dir = sys.argv[3]
nodes_db = os.path.join(config_dir, "all_nodes.txt")

def generate_subscriptions():
    all_links_path = os.path.join(config_dir, "all_links.txt")
    box_links_path = os.path.join(config_dir, "box_links.json")
    mi_links_path = os.path.join(config_dir, "mi_links.yaml")

    mi_proxies = []
    box_outbounds = []
    all_links = []
    node_names = []

    if os.path.exists(nodes_db):
        with open(nodes_db, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                
                parts = {}
                for item in line.split("|"):
                    if "=" in item:
                        k, v = item.split("=", 1)
                        parts[k] = v

                node_type = parts.get("TYPE")

                # 1. 解析 VLESS-REALITY 节点
                if node_type == "vless-reality":
                    name = parts.get("NAME", "node").replace("-in-", "-out-")
                    ip = parts.get("IP", "127.0.0.1")
                    port_val = parts.get("PORT", "443")
                    uuid = parts.get("UUID", "")
                    pub = parts.get("PUB", "")
                    shortid = parts.get("SHORTID", "")
                    domain = parts.get("DOMAIN", "gateway.icloud.com")

                    node_names.append(name)

                    mi_proxy = f\"\"\"  - name: "{name}"
    type: vless
    server: {ip}
    port: {port_val}
    uuid: {uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    servername: {domain}
    reality-opts:
      public-key: {pub}
      short-id: {shortid}
      support-x25519mlkem768: false\"\"\"
                    mi_proxies.append(mi_proxy)

                    box_dict = {
                        "type": "vless",
                        "tag": name,
                        "server": ip,
                        "server_port": int(port_val),
                        "uuid": uuid,
                        "flow": "xtls-rprx-vision",
                        "tls": {
                            "enabled": True,
                            "server_name": domain,
                            "utls": {
                                "enabled": True,
                                "fingerprint": "chrome"
                            },
                            "reality": {
                                "enabled": True,
                                "public_key": pub,
                                "short_id": shortid
                            }
                        }
                    }
                    box_outbounds.append(box_dict)

                    encoded_name = urllib.parse.quote(name)
                    vless_link = f"vless://{uuid}@{ip}:{port_val}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={domain}&fp=chrome&pbk={pub}&sid={shortid}#{encoded_name}"
                    all_links.append(vless_link)

                # 2. 解析 Hysteria 2 节点（支持自签证书 SHA-256 指纹校验）
                elif node_type == "hysteria2":
                    name = parts.get("NAME", "hy2-node").replace("-in-", "-out-")
                    ip = parts.get("IP", "127.0.0.1")
                    port_val = parts.get("PORT", "443")
                    password = parts.get("PASSWORD", "")
                    fingerprint = parts.get("FINGERPRINT", "")
                    sni = parts.get("SNI", "gateway.icloud.com")

                    node_names.append(name)

                    mi_proxy = f\"\"\"  - name: "{name}"
    type: hysteria2
    server: {ip}
    port: {port_val}
    password: {password}
    sni: {sni}
    skip-cert-verify: false
    fingerprint: {fingerprint}
    alpn:
      - h3\"\"\"
                    mi_proxies.append(mi_proxy)

                    box_dict = {
                        "type": "hysteria2",
                        "tag": name,
                        "server": ip,
                        "server_port": int(port_val),
                        "password": password,
                        "tls": {
                            "enabled": True,
                            "server_name": sni,
                            "insecure": True,
                            "alpn": ["h3"]
                        }
                    }
                    box_outbounds.append(box_dict)

                    encoded_name = urllib.parse.quote(name)
                    hy2_link = f"hysteria2://{password}@{ip}:{port_val}?sni={sni}&pinSHA256={fingerprint}#{encoded_name}"
                    all_links.append(hy2_link)

    proxies_list_6 = "\n".join([f\x27      - "{n}"\x27 for n in node_names]) if node_names else \x27      - "DIRECT"\x27

    mihomo_full_config = f\"\"\"port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
dns:
  enable: true 
  listen: "0.0.0.0:1053"
  ipv6: true
  prefer-h3: false
  respect-rules: true
  use-system-hosts: false
  cache-algorithm: "arc"
  enhanced-mode: "fake-ip"
  fake-ip-range: "198.18.0.1/16"
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "localhost.ptlogin2.qq.com"
    - "localhost.sec.qq.com"
    - "+.in-addr.arpa"
    - "+.ip6.arpa"
    - "time.*.com"
    - "time.*.gov"
    - "pool.ntp.org"
    - "localhost.work.weixin.qq.com"
  default-nameserver: ["223.5.5.5", "119.29.29.29"]
  nameserver:
    - "https://1.1.1.1/dns-query"
    - "https://8.8.8.8/dns-query"
  proxy-server-nameserver:
    - "https://223.5.5.5/dns-query"
    - "https://doh.pub/dns-query"

proxies:
\"\"\" + ("\n\n".join(mi_proxies) if mi_proxies else "") + f\"\"\"

proxy-groups:
  - name: 负载均衡
    type: load-balance
    url: https://www.gstatic.com/generate_204
    interval: 300
    strategy: round-robin
    proxies:
{proxies_list_6}

  - name: 自动选择
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
{proxies_list_6}

  - name: 🌍选择代理节点
    type: select
    proxies:
      - 负载均衡
      - 自动选择
      - DIRECT
{proxies_list_6}

rules:
  - GEOIP,LAN,DIRECT
  - GEOSITE,CN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🌍选择代理节点
\"\"\"
    with open(mi_links_path, "w", encoding="utf-8") as f:
        f.write(mihomo_full_config)

    selector_outbounds = ["auto"] + node_names if node_names else ["direct"]
    auto_outbounds = node_names if node_names else ["direct"]

    singbox_full_config = {
        "log": {
            "level": "info",
            "timestamp": True
        },
        "http_clients": [
            {
                "tag": "rule-set-direct"
            }
        ],
        "dns": {
            "servers": [
                {
                    "type": "fakeip",
                    "tag": "fakeip",
                    "inet4_range": "198.18.0.0/15",
                    "inet6_range": "fc00::/18"
                },
                {
                    "type": "udp",
                    "tag": "dns-cn",
                    "server": "223.5.5.5",
                    "server_port": 53
                },
                {
                    "type": "https",
                    "tag": "dns-proxy",
                    "server": "dns.google",
                    "domain_resolver": "dns-cn",
                    "detour": "proxy"
                }
            ],
            "rules": [
                {
                    "rule_set": ["geosite-cn"],
                    "action": "route",
                    "server": "dns-cn"
                },
                {
                    "query_type": ["A", "AAAA"],
                    "action": "route",
                    "server": "fakeip"
                }
            ],
            "final": "dns-proxy",
            "strategy": "prefer_ipv4",
            "cache_capacity": 8192,
            "optimistic": {
                "enabled": True,
                "timeout": "1h"
            },
            "timeout": "10s",
            "reverse_mapping": True
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": [
                    "172.19.0.1/30",
                    "fdfe:dcba:9876::1/126"
                ],
                "auto_route": True,
                "strict_route": True,
                "mtu": 1420
            }
        ],
        "outbounds": [
            {
                "type": "selector",
                "tag": "proxy",
                "default": "auto",
                "outbounds": selector_outbounds
            },
            {
                "type": "urltest",
                "tag": "auto",
                "outbounds": auto_outbounds,
                "url": "https://www.gstatic.com/generate_204",
                "interval": "10m",
                "tolerance": 30,
                "idle_timeout": "30m"
            },
            {
                "type": "direct",
                "tag": "direct"
            }
        ] + box_outbounds,
        "route": {
            "default_http_client": "rule-set-direct",
            "default_domain_resolver": "dns-cn",
            "auto_detect_interface": True,
            "rule_set": [
                {
                    "tag": "geosite-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs"
                },
                {
                    "tag": "geoip-cn",
                    "type": "remote",
                    "format": "binary",
                    "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs"
                }
            ],
            "rules": [
                {
                    "inbound": ["tun-in"],
                    "protocol": ["dns"],
                    "action": "hijack-dns"
                },
                {
                    "clash_mode": "Global",
                    "action": "route",
                    "outbound": "proxy"
                },
                {
                    "ip_is_private": True,
                    "action": "route",
                    "outbound": "direct"
                },
                {
                    "rule_set": ["geosite-cn"],
                    "action": "route",
                    "outbound": "direct"
                },
                {
                    "rule_set": ["geoip-cn"],
                    "action": "route",
                    "outbound": "direct"
                },
                {
                    "clash_mode": "Direct",
                    "action": "route",
                    "outbound": "direct"
                },
                {
                    "network": ["tcp", "udp"],
                    "port": 853,
                    "action": "reject"
                }
            ],
            "final": "proxy"
        },
        "experimental": {
            "cache_file": {
                "enabled": True,
                "store_dns": True
            },
            "clash_api": {
                "external_controller": "127.0.0.1:9090",
                "external_ui": "ui",
                "default_mode": "Rule"
            }
        }
    }

    with open(box_links_path, "w", encoding="utf-8") as f:
        json.dump(singbox_full_config, f, indent=2, ensure_ascii=False)

    with open(all_links_path, "w", encoding="utf-8") as f:
        f.write("\n".join(all_links) + "\n")

generate_subscriptions()

class MultiSubHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        query_params = urllib.parse.parse_qs(parsed_path.query)
        user_token = query_params.get(\x27token\x27, [\x27\x27])[0]

        if user_token != token:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b\x27Access Denied: Invalid or Missing Token\x27)
            return

        generate_subscriptions()

        if parsed_path.path in [\x27/\x27, \x27/all\x27]:
            self.send_response(200)
            self.send_header(\x27Content-Type\x27, \x27text/plain; charset=utf-8\x27)
            self.end_headers()
            with open(os.path.join(config_dir, \x27all_links.txt\x27), \x27rb\x27) as f:
                raw_data = f.read()
                self.wfile.write(base64.b64encode(raw_data))
        elif parsed_path.path == \x27/raw\x27:
            self.send_response(200)
            self.send_header(\x27Content-Type\x27, \x27text/plain; charset=utf-8\x27)
            self.end_headers()
            with open(os.path.join(config_dir, \x27all_links.txt\x27), \x27rb\x27) as f:
                self.wfile.write(f.read())
        elif parsed_path.path == \x27/box\x27:
            self.send_response(200)
            self.send_header(\x27Content-Type\x27, \x27application/json; charset=utf-8\x27)
            self.end_headers()
            with open(os.path.join(config_dir, \x27box_links.json\x27), \x27rb\x27) as f:
                self.wfile.write(f.read())
        elif parsed_path.path == \x27/mi\x27:
            self.send_response(200)
            self.send_header(\x27Content-Type\x27, \x27text/yaml; charset=utf-8\x27)
            self.end_headers()
            with open(os.path.join(config_dir, \x27mi_links.yaml\x27), \x27rb\x27) as f:
                self.wfile.write(f.read())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b\x27Not Found\x27)

    def log_message(self, format, *args):
        pass

server = http.server.HTTPServer((\x270.0.0.0\x27, port), MultiSubHandler)
server.serve_forever()
"""

target_file = os.environ["YD_PYTHON_SERVER_FILE"]
os.makedirs(os.path.dirname(target_file), exist_ok=True)
with open(target_file, "w", encoding="utf-8") as f:
    f.write(server_code)
'
}

start_daemon() {
    if [ ! -f "$NODES_DB" ]; then
        echo -e "${RED}[ERROR] 找不到总账本文件: ${NODES_DB}${NC}"
        echo -e "${YELLOW}[INFO] 请先运行 config.sh 生成服务端节点！${NC}"
        return 1
    fi

    stop_daemon

    if [ ! -f "$TOKEN_FILE" ]; then
        openssl rand -hex 32 > "$TOKEN_FILE"
    fi

    local raw_port
    raw_port=$(get_web_port)
    local web_port
    web_port=$(echo "$raw_port" | grep -oE '[0-9]+' | tail -n 1)

    if [ ! -f "$TOKEN_FILE" ]; then
        openssl rand -hex 32 > "$TOKEN_FILE"
    fi
    SUB_TOKEN=$(cat "$TOKEN_FILE")

    prepare_python_server
    manage_firewall_port "add" "$web_port" "YinDun-Sub-${web_port}"

    local server_ip
    server_ip=$(get_public_ip)

    cd "${CONFIG_DIR}" || exit
    nohup python3 sub_server.py "$web_port" "$SUB_TOKEN" "${CONFIG_DIR}" >/dev/null 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${GREEN}  YinDun 客户端订阅守护进程已在后台成功启动！${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "服务进程 PID : ${YELLOW}${new_pid}${NC}"
    echo -e "当前服务端口 : ${YELLOW}${web_port}${NC} (已持久化固化)"
    echo -e "安全 Token   : ${YELLOW}${SUB_TOKEN}${NC}"
    echo -e "${CYAN}--------------------------------------------------------${NC}"
    echo -e "1. 主订阅链接 (支持直接作为客户端订阅源导入，返回 Base64):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/?token=${SUB_TOKEN}${NC}"
    echo -e "2. 原文明文链接 (all_links.txt):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/raw?token=${SUB_TOKEN}${NC}"
    echo -e "3. Sing-box 专属订阅 (高级 Fake-IP 客户端配置):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/box?token=${SUB_TOKEN}${NC}"
    echo -e "4. Mihomo 专属订阅 (高级 Fake-IP + 负载均衡模板):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/mi?token=${SUB_TOKEN}${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}[INFO] VLESS-REALITY 与 Hysteria 2 双端订阅均已就绪！${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    start_daemon
fi
