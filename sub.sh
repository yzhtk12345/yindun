#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Client Subscription Manager & Web Daemon (sub.sh)
# Description: 纯客户端订阅分发守护进程：Web端口(10000-20000)+防火墙联动+Systemd开机自启
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
NODES_DB="${CONFIG_DIR}/all_nodes.txt"
PORT_RECORD_FILE="${CONFIG_DIR}/sub_web_port.txt"

ALL_LINKS_FILE="${CONFIG_DIR}/all_links.txt"
BOX_LINKS_FILE="${CONFIG_DIR}/box_links.json"
MI_LINKS_FILE="${CONFIG_DIR}/mi_links.yaml"

TOKEN_FILE="${CONFIG_DIR}/sub_token.txt"
if [ ! -f "$TOKEN_FILE" ]; then
    openssl rand -hex 32 > "$TOKEN_FILE"
fi
SUB_TOKEN=$(cat "$TOKEN_FILE")

# 检测系统防火墙类型
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

# 清理旧的 YinDun 订阅 Web 端口防火墙规则
cleanup_old_sub_firewall_rules() {
    local fw_type
    fw_type=$(detect_firewall)
    echo -e "${CYAN}[INFO] 正在清理防火墙中的旧 YinDun 订阅 Web 端口规则...${NC}"

    # 如果有历史记录的端口，优先精准清除
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
            echo -e "${YELLOW}[INFO] 已清理历史旧订阅端口: ${old_port}${NC}"
        fi
        rm -f "$PORT_RECORD_FILE"
    fi

    # 通用防御：通过 UFW 备注清理带 YinDun-Sub 的规则
    if [[ "$fw_type" == "ufw" ]]; then
        while true; do
            local rule_num
            rule_num=$(ufw status numbered | grep "YinDun-Sub" | head -n 1 | awk -F'[][]' '{print $2}')
            [[ -z "$rule_num" ]] && break
            yes | ufw delete "$rule_num" >/dev/null 2>&1
        done
        ufw reload >/dev/null 2>&1
    fi
}

# 防火墙开放端口
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
                echo -e "${GREEN}[UFW] 已开放订阅 Web 端口 ${port}/tcp (备注: ${comment})${NC}"
            fi
            ;;
        firewalld)
            if [[ "$action" == "add" ]]; then
                firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                echo -e "${GREEN}[Firewalld] 已永久开放订阅 Web 端口 ${port}/tcp${NC}"
            fi
            ;;
        iptables)
            if [[ "$action" == "add" ]]; then
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
                echo -e "${GREEN}[Iptables] 已开放订阅 Web 端口 ${port}/tcp${NC}"
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

# 生成所有客户端订阅文件
generate_all_subscriptions() {
    if [ ! -f "$NODES_DB" ]; then
        echo -e "${RED}[ERROR] 找不到总账本文件: ${NODES_DB}${NC}"
        return 1
    }

    cat <<EOF > "$MI_LINKS_FILE"
# YinDun Mihomo Subscription (mi_links.yaml)
proxies:
EOF

    cat <<EOF > "$BOX_LINKS_FILE"
{
  "outbounds": [
EOF

    > "$ALL_LINKS_FILE"

    local box_items=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local type_val name_val port_val uuid_val pub_val shortid_val domain_val ip_val
        type_val=$(echo "$line" | grep -oP 'TYPE=\K[^|]+')
        name_val=$(echo "$line" | grep -oP 'NAME=\K[^|]+')
        port_val=$(echo "$line" | grep -oP 'PORT=\K[^|]+')
        uuid_val=$(echo "$line" | grep -oP 'UUID=\K[^|]+')
        pub_val=$(echo "$line" | grep -oP 'PUB=\K[^|]+')
        shortid_val=$(echo "$line" | grep -oP 'SHORTID=\K[^|]+')
        domain_val=$(echo "$line" | grep -oP 'DOMAIN=\K[^|]+')
        ip_val=$(echo "$line" | grep -oP 'IP=\K[^|]+')

        if [[ "$type_val" == "vless-reality" ]]; then
            local client_node_name="${name_val//-in-/-out-}"

            cat <<EOF >> "$MI_LINKS_FILE"
  - name: "${client_node_name}"
    type: vless
    server: ${ip_val}
    port: ${port_val}
    uuid: ${uuid_val}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    servername: ${domain_val}
    reality-opts:
      public-key: ${pub_val}
      short-id: ${shortid_val}
      support-x25519mlkem768: false
EOF

            local box_snippet="    {
      \"type\": \"vless\",
      \"tag\": \"${client_node_name}\",
      \"server\": \"${ip_val}\",
      \"server_port\": ${port_val},
      \"uuid\": \"${uuid_val}\",
      \"flow\": \"xtls-rprx-vision\",
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${domain_val}\",
        \"utls\": {
          \"enabled\": true,
          \"fingerprint\": \"chrome\"
        },
        \"reality\": {
          \"enabled\": true,
          \"public_key\": \"${pub_val}\",
          \"short_id\": \"${shortid_val}\"
        }
      }
    }"
            box_items+=("$box_snippet")

            local encoded_name
            encoded_name=$(echo -n "${client_node_name}" | jq -sRr @uri 2>/dev/null || echo "${client_node_name}")
            local vless_link="vless://${uuid_val}@${ip_val}:${port_val}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain_val}&fp=chrome&pbk=${pub_val}&sid=${shortid_val}#${encoded_name}"
            echo "$vless_link" >> "$ALL_LINKS_FILE"
        fi
    done < "$NODES_DB"

    local joined_box_items=""
    if [ ${#box_items[@]} -gt 0 ]; then
        (
          IFS=$',\n'
          echo "${box_items[*]}"
        ) > /tmp/yindun_box_items.tmp
        joined_box_items=$(cat /tmp/yindun_box_items.tmp)
        rm -f /tmp/yindun_box_items.tmp
    fi

    cat <<EOF >> "$BOX_LINKS_FILE"
${joined_box_items}
  ]
}
EOF
}

# 核心守护主逻辑：清理旧端口 -> 随机分配新端口(10000-20000) -> 写入防火墙 -> 启动 Python Web 服务
run_web_daemon() {
    # 1. 自动清理历史旧端口及防火墙残留
    cleanup_old_sub_firewall_rules

    # 2. 生成订阅内容
    generate_all_subscriptions || return 1

    # 3. 在 10000-20000 范围内随机分配可用端口
    local web_port
    web_port=$(get_web_port)
    echo "$web_port" > "$PORT_RECORD_FILE"

    # 4. 动态写入防火墙规则
    manage_firewall_port "add" "$web_port" "YinDun-Sub-${web_port}"

    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null || echo "YOUR_SERVER_IP")

    # 创建 Python 后端分发脚本
    cat << 'PY_SERVER_EOF' > "${CONFIG_DIR}/sub_server.py"
import http.server
import urllib.parse
import sys

port = int(sys.argv[1])
token = sys.argv[2]

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

        if parsed_path.path == '/all':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            with open('all_links.txt', 'rb') as f:
                self.wfile.write(f.read())
        elif parsed_path.path == '/box':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.end_headers()
            with open('box_links.json', 'rb') as f:
                self.wfile.write(f.read())
        elif parsed_path.path == '/mi':
            self.send_response(200)
            self.send_header('Content-Type', 'text/yaml; charset=utf-8')
            self.end_headers()
            with open('mi_links.yaml', 'rb') as f:
                self.wfile.write(f.read())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')

    def log_message(self, format, *args):
        print(f'[WEB LOG] {args[0]}')

server = http.server.HTTPServer(('0.0.0.0', port), MultiSubHandler)
server.serve_forever()
PY_SERVER_EOF

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${GREEN}  YinDun 客户端订阅守护进程已成功启动！${NC}"
    echo -e "${CYAN}========================================================${NC} "
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

    # 注册并启用 Systemd 系统服务（实现开机默默自启与后台常驻）
    local systemd_service_file="/etc/systemd/system/yindun-sub.service"
    if [ ! -f "$systemd_service_file" ]; then
        cat <<EOF > "$systemd_service_file"
[Unit]
Description=YinDun Multi-Client Subscription Daemon
After=network.target network-online.target mihomo.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=/usr/bin/python3 ${CONFIG_DIR}/sub_server.py ${web_port} ${SUB_TOKEN}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable yindun-sub.service >/dev/null 2>&1
        echo -e "${GREEN}[INFO] 已自动注册 Systemd 服务，并设置为开机默默自启！${NC}"
    else
        # 如果服务文件已存在，更新其中的端口
        sed -i "s|sub_server.py [0-9]*|sub_server.py ${web_port}|g" "$systemd_service_file"
        systemctl daemon-reload >/dev/null 2>&1
    fi

    cd "${CONFIG_DIR}" || exit
    python3 sub_server.py "$web_port" "$SUB_TOKEN"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_web_daemon
fi
