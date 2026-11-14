#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Client Subscription Manager & Background Daemon (sub.sh)
# Description: 纯客户端订阅分发守护进程：完美隔离函数输出、精准持久化端口与 Token
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

    # 仅输出纯数字，绝对杜绝污染变量
    echo "${target_port//[!0-9]/}"
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
    echo "YOUR_SERVER_IP"
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

create_python_server_script() {
    cat << 'EOF' > "$PYTHON_SERVER_FILE"
import http.server
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

                if parts.get("TYPE") == "vless-reality":
                    name = parts.get("NAME", "node").replace("-in-", "-out-")
                    ip = parts.get("IP", "127.0.0.1")
                    port_val = parts.get("PORT", "443")
                    uuid = parts.get("UUID", "")
                    pub = parts.get("PUB", "")
                    shortid = parts.get("SHORTID", "")
                    domain = parts.get("DOMAIN", "gateway.icloud.com")

                    mi_proxy = f'  - name: "{name}"\n    type: vless\n    server: {ip}\n    port: {port_val}\n    uuid: {uuid}\n    network: tcp\n    tls: true\n    udp: true\n    flow: xtls-rprx-vision\n    client-fingerprint: chrome\n    servername: {domain}\n    reality-opts:\n      public-key: {pub}\n      short-id: {shortid}\n      support-x25519mlkem768: false'
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

    with open(mi_links_path, "w", encoding="utf-8") as f:
        f.write("# YinDun Mihomo Subscription (mi_links.yaml)\nproxies:\n" + "\n".join(mi_proxies) + "\n")

    with open(box_links_path, "w", encoding="utf-8") as f:
        json.dump({"outbounds": box_outbounds}, f, indent=2, ensure_ascii=False)

    with open(all_links_path, "w", encoding="utf-8") as f:
        f.write("\n".join(all_links) + "\n")

generate_subscriptions()

class MultiSubHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        query_params = urllib.parse.parse_qs(parsed_path.query)
        user_token = query_params.get('token', [''])[0]

        if user_token != token:
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'Access Denied: Invalid or Missing Token')
            return

        generate_subscriptions()

        if parsed_path.path in ['/', '/all']:
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            with open(os.path.join(config_dir, 'all_links.txt'), 'rb') as f:
                raw_data = f.read()
                self.wfile.write(base64.b64encode(raw_data))
        elif parsed_path.path == '/raw':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            with open(os.path.join(config_dir, 'all_links.txt'), 'rb') as f:
                self.wfile.write(f.read())
        elif parsed_path.path == '/box':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.end_headers()
            with open(os.path.join(config_dir, 'box_links.json'), 'rb') as f:
                self.wfile.write(f.read())
        elif parsed_path.path == '/mi':
            self.send_response(200)
            self.send_header('Content-Type', 'text/yaml; charset=utf-8')
            self.end_headers()
            with open(os.path.join(config_dir, 'mi_links.yaml'), 'rb') as f:
                self.wfile.write(f.read())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')

    def log_message(self, format, *args):
        pass

server = http.server.HTTPServer(('0.0.0.0', port), MultiSubHandler)
server.serve_forever()
EOF
}

start_daemon() {
    if [ ! -f "$NODES_DB" ]; then
        echo -e "${RED}[ERROR] 找不到总账本文件: ${NODES_DB}${NC}"
        echo -e "${YELLOW}[INFO] 请先运行 config.sh 生成服务端节点！${NC}"
        return 1
    fi

    stop_daemon

    # Token 持久化处理
    if [ ! -f "$TOKEN_FILE" ]; then
        openssl rand -hex 32 > "$TOKEN_FILE"
    fi

    local web_port
    web_port=$(get_web_port)

    # 如果刚才选择了重置 Token，这里重新生成
    if [ ! -f "$TOKEN_FILE" ]; then
        openssl rand -hex 32 > "$TOKEN_FILE"
    fi
    SUB_TOKEN=$(cat "$TOKEN_FILE")

    create_python_server_script
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
    echo -e "3. Sing-box 专属订阅 (box_links.json):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/box?token=${SUB_TOKEN}${NC}"
    echo -e "4. Mihomo 专属订阅 (mi_links.yaml):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/mi?token=${SUB_TOKEN}${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}[INFO] 订阅守护进程运行平稳，所有日志与输出已完美隔离！${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    start_daemon
fi
