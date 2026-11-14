#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Multi-Client Subscription & Web Server (sub.sh)
# Description: 纯客户端订阅分发中心：Web服务端口(10000-20000)，生成 all_links.txt, box_links.json, mi_links.yaml
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
NODES_DB="${CONFIG_DIR}/all_nodes.txt"

# 订阅文件路径定义
ALL_LINKS_FILE="${CONFIG_DIR}/all_links.txt"
BOX_LINKS_FILE="${CONFIG_DIR}/box_links.json"
MI_LINKS_FILE="${CONFIG_DIR}/mi_links.yaml"

# 生成超长、更乱的高强度安全 Token
TOKEN_FILE="${CONFIG_DIR}/sub_token.txt"
if [ ! -f "$TOKEN_FILE" ]; then
    openssl rand -hex 32 > "$TOKEN_FILE"
fi
SUB_TOKEN=$(cat "$TOKEN_FILE")

# 检查端口占用工具
check_port_used() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tuln | grep -q ":${port} " && return 0 || return 1
    else
        nc -z 127.0.0.1 "$port" &>/dev/null && return 0 || return 1
    fi
}

# 获取订阅 Web 服务端口（10000-20000随机或手动）
get_web_port() {
    echo -e "${CYAN}--------------------------------------------------------${NC}"
    read -p "请选择订阅 Web 服务的端口获取方式 [1. 随机获取(10000-20000) 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto"
    local target_port=""

    if [[ "$port_mode_choice" == "2" ]]; then
        port_mode="manual"
        read -p "请输入您指定的 Web 端口 [1-65535]: " target_port
    fi

    if [[ "$port_mode" == "manual" ]]; then
        if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
            echo -e "${RED}[ERROR] 端口输入无效，使用默认随机分配${NC}"
            port_mode="auto"
        fi
    fi

    if [[ "$port_mode" == "auto" ]]; then
        while true; do
            target_port=$((RANDOM % 10001 + 10000))
            if ! check_port_used "$target_port"; then
                break
            fi
        done
        echo -e "${GREEN}[INFO] 自动为订阅 Web 服务分配端口 [10000-20000]: ${target_port}${NC}"
    else
        echo -e "${GREEN}[INFO] 已指定订阅 Web 服务端口: ${target_port}${NC}"
    fi

    echo "$target_port"
}

# 生成所有客户端订阅文件
generate_all_subscriptions() {
    if [ ! -f "$NODES_DB" ]; then
        echo -e "${RED}[ERROR] 找不到总账本文件: ${NODES_DB}${NC}"
        echo -e "${YELLOW}[INFO] 请先运行 config.sh 生成服务端节点！${NC}"
        return 1
    fi

    # 1. 生成 mi_links.yaml (Mihomo 专属)
    cat <<EOF > "$MI_LINKS_FILE"
# YinDun Mihomo Subscription (mi_links.yaml)
proxies:
EOF

    # 2. 生成 box_links.json (Sing-box 专属)
    cat <<EOF > "$BOX_LINKS_FILE"
{
  "outbounds": [
EOF

    # 3. 初始化 all_links.txt (通用链接)
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

            # 写入 mi_links.yaml
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

            # 写入 box_links.json 片段
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

            # 写入 all_links.txt (通用 vless 链接)
            local encoded_name
            encoded_name=$(echo -n "${client_node_name}" | jq -sRr @uri 2>/dev/null || echo "${client_node_name}")
            local vless_link="vless://${uuid_val}@${ip_val}:${port_val}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain_val}&fp=chrome&pbk=${pub_val}&sid=${shortid_val}#${encoded_name}"
            echo "$vless_link" >> "$ALL_LINKS_FILE"
        fi
    done < "$NODES_DB"

    # 组装 box_links.json 闭合
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

# 启动 Web 订阅服务
start_web_server() {
    generate_all_subscriptions || return 1

    local web_port
    web_port=$(get_web_port)

    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null || echo "YOUR_SERVER_IP")

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${GREEN}  YinDun 客户端订阅 Web 服务已成功启动！${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "安全 Token (高强度随机):"
    echo -e "${YELLOW}${SUB_TOKEN}${NC}"
    echo -e "${CYAN}--------------------------------------------------------${NC}"
    echo -e "1. 通用订阅 (all_links.txt - 适用于 V2ray / 虎兕 / throne 等):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/all?token=${SUB_TOKEN}${NC}"
    echo -e "2. Sing-box 专属订阅 (box_links.json):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/box?token=${SUB_TOKEN}${NC}"
    echo -e "3. Mihomo 专属订阅 (mi_links.yaml):"
    echo -e "   ${GREEN}http://${server_ip}:${web_port}/mi?token=${SUB_TOKEN}${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${YELLOW}提示: 按 Ctrl+C 可以停止当前 Web 服务。${NC}"

    cd "${CONFIG_DIR}" || exit

    python3 -c "
import http.server
import urllib.parse

PORT = ${web_port}
TOKEN = '${SUB_TOKEN}'

class MultiSubHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        query_params = urllib.parse.parse_qs(parsed_path.query)
        user_token = query_params.get('token', [''])[0]

        if user_token != TOKEN:
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

server = http.server.HTTPServer(('0.0.0.0', PORT), MultiSubHandler)
server.serve_forever()
"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    start_web_server
fi
