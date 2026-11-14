#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Client Subscription Manager & Background Daemon (sub.sh)
# Description: 纯客户端订阅分发守护进程：支持后台静默运行、停止和状态检查
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

TOKEN_FILE="${CONFIG_DIR}/sub_token.txt"
if [ ! -f "$TOKEN_FILE" ]; then
    openssl rand -hex 32 > "$TOKEN_FILE"
fi
SUB_TOKEN=$(cat "$TOKEN_FILE")

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
        rm -f "$PORT_RECORD_FILE"
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
    while true; do
        target_port=$((RANDOM % 10001 + 10000))
        if ! check_port_used "$target_port"; then
            break
        fi
    done
    echo "${target_port}"
}

# 停止后台服务
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
    cleanup_old_sub_firewall_rules
}

# 启动后台服务
start_daemon() {
    if [ ! -f "$NODES_DB" ]; then
        echo -e "${RED}[ERROR] 找不到总账本文件: ${NODES_DB}${NC}"
        echo -e "${YELLOW}[INFO] 请先运行 config.sh 生成服务端节点！${NC}"
        return 1
    }

    # 先停掉旧的
    stop_daemon

    local web_port
    web_port=$(get_web_port)
    echo "$web_port" > "$PORT_RECORD_FILE"

    manage_firewall_port "add" "$web_port" "YinDun-Sub-${web_port}"

    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null || echo "YOUR_SERVER_IP")

    # 创建 Python 后端分发脚本
    cat << 'PY_SERVER_EOF' > "${CONFIG_DIR}/sub_server.py"
import http.server
import urllib.parse
import sys
import os

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
                    port = parts.get("PORT", "443")
                    uuid = parts.get("UUID", "")
                    pub = parts.get("PUB", "")
                    shortid = parts.get("SHORTID", "")
                    domain = parts.get("DOMAIN", "gateway.icloud.com")

                    mi_proxy = f"""  - name: "{name}"
    type: vless
    server: {ip}
    port: {port}
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
      support-x25519mlkem768: false"""
                    mi_proxies.append(mi_proxy)

                    box_item = f"""    {{
      "type": "vless",
      "tag": "{name}",
      "server": "{ip}",
      "server_port": {port},
      "uuid": "{uuid}",
      "flow": "xtls-rprx-vision",
      "tls": {{
        "enabled": True,
        "server_name": "{domain}",
        "utls": {{
          "enabled": True,
          "fingerprint": "chrome"
        }},
        "reality": {{
          "enabled": True,
          "public_key": "{pub}",
          "short_id": "{shortid}"
        }}
      }}
    }}"""
                    box_outbounds.append(box_item)

                    encoded_name = urllib.parse.quote(name)
                    vless_link = f"vless://{uuid}@{ip}:{port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={domain}&fp=chrome&pbk={pub}&sid={shortid}#{encoded_name}"
                    all_links.append(vless_link)

    with open(mi_links_path, "w", encoding="utf-8") as f:
        f.write("# YinDun Mihomo Subscription (mi_links.yaml)\nproxies:\n" + "\n".join(mi_proxies) + "\n")

    with open(box_links_path, "w", encoding="utf-8") as f:
        f.write("{\n  \"outbounds\": [\n" + ",\n".join(box_outbounds) + "\n  ]\n}\n")

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

        if parsed_path.path == '/all':
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
        pass  # 静默运行，不刷屏

server = http.server.HTTPServer(('0.0.0.0', port), MultiSubHandler)
server.serve_forever()
PY_SERVER_EOF

    # 在后台静默运行 Python 服务
    cd "${CONFIG_DIR}" || exit
    nohup python3 sub_server.py "$web_port" "$SUB_TOKEN" "${CONFIG_DIR}" >/dev/null 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${GREEN}  YinDun 客户端订阅守护进程已在后台成功启动！${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "服务进程 PID : ${YELLOW}${new_pid}${NC}"
    echo -e "当前服务端口 : ${YELLOW}${web_port}${NC}"
    echo -e "安全 Token   : ${YELLOW}${SUB_TOKEN}${NC}"
    echo -e "${CYAN}--------------------------------------------------------${NC}"
    echo -e "1. 通用订阅 (all_links.txt):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/all?token=${SUB_TOKEN}${NC}"
    echo -e "2. Sing-box 专属订阅 (box_links.json):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/box?token=${SUB_TOKEN}${NC}"
    echo -e "3. Mihomo 专属订阅 (mi_links.yaml):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/mi?token=${SUB_TOKEN}${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}[INFO] 脚本已安全退出，服务正在后台平稳运行，无需按 Ctrl+C！${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    start_daemon
fi
