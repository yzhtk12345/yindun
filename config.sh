#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Configuration Manager (config.sh)
# Description: 1~10号全功能对等、完整协议落地、全局安全增量合并、Argo 443平铺版
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
NODES_DB="${CONFIG_DIR}/all_nodes.txt"

mkdir -p "${CONFIG_DIR}"

check_and_install_dependencies() {
    if ! command -v ss &>/dev/null || ! command -v openssl &>/dev/null; then
        echo -e "${YELLOW}[INFO] 检测到系统缺少基础网络或加密工具，正在自动安装...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y iproute2 openssl curl &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y iproute openssl curl &>/dev/null
        fi
    fi
}

check_and_install_python() {
    if ! command -v python3 &>/dev/null || ! python3 -c "import yaml" &>/dev/null; then
        echo -e "${YELLOW}[INFO] 检测到系统缺少 Python 3 或 PyYAML，正在自动安装...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y python3 python3-yaml &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y python3 python3-PyYAML &>/dev/null || yum install -y python3 python3-yaml &>/dev/null || true
        fi
    fi
}

check_and_install_cloudflared() {
    local cf_bin="${CONFIG_DIR}/cloudflared"
    [ -x "$cf_bin" ] && return 0
    if command -v cloudflared &>/dev/null; then
        ln -sf "$(command -v cloudflared)" "$cf_bin"
        return 0
    fi
    local arch=$(uname -m)
    local cf_arch="amd64"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && cf_arch="arm64"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    if curl -L -s --max-time 60 "$url" -o "$cf_bin"; then
        chmod +x "$cf_bin"
        return 0
    fi
    return 1
}

check_port_used() {
    local port="$1"
    check_and_install_dependencies
    if ss -tuln | grep -q ":${port} "; then
        return 0
    else
        return 1
    fi
}

get_available_port() {
    local mode="$1"
    local manual_port="$2"
    local target_port=""

    if [[ "$mode" == "manual" ]]; then
        if [[ -z "$manual_port" ]]; then
            read -p "请输入您指定的端口 [20000-60000]: " target_port >&2
        else
            target_port="$manual_port"
        fi

        if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
            echo -e "${RED}[ERROR] 端口输入无效！${NC}" >&2
            return 1
        fi

        if check_port_used "$target_port"; then
            echo -e "${YELLOW}[WARN] 端口 ${target_port} 当前已被占用！${NC}" >&2
            read -p "是否仍要强行使用此端口？[y/N]: " force_choice >&2
            if [[ "$force_choice" != "y" && "$force_choice" != "Y" ]]; then
                return 1
            fi
        fi
    else
        while true; do
            target_port=$((RANDOM % 40001 + 20000))
            if ! check_port_used "$target_port"; then
                break
            fi
        done
        echo -e "${GREEN}[INFO] 自动分配可用端口: ${target_port}${NC}" >&2
    fi
    echo "$target_port"
}

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

cleanup_firewall_by_type() {
    local target_type="$1"
    local fw_type
    fw_type=$(detect_firewall)

    if [ -f "$NODES_DB" ]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if echo "$line" | grep -q "TYPE=${target_type}|"; then
                local old_p
                old_p=$(echo "$line" | grep -oP 'PORT=\K[^|]+')
                if [[ -n "$old_p" ]]; then
                    case "$fw_type" in
                        ufw)
                            ufw delete allow "${old_p}/tcp" >/dev/null 2>&1
                            ufw delete allow "${old_p}/udp" >/dev/null 2>&1
                            ;;
                        firewalld)
                            firewall-cmd --permanent --remove-port="${old_p}/tcp" >/dev/null 2>&1
                            firewall-cmd --permanent --remove-port="${old_p}/udp" >/dev/null 2>&1
                            ;;
                        iptables)
                            iptables -D INPUT -p tcp --dport "$old_p" -j ACCEPT 2>/dev/null || true
                            iptables -D INPUT -p udp --dport "$old_p" -j ACCEPT 2>/dev/null || true
                            ;;
                    esac
                fi
            fi
        done < "$NODES_DB"

        case "$fw_type" in
            ufw) ufw reload >/dev/null 2>&1 ;;
            firewalld) firewall-cmd --reload >/dev/null 2>&1 ;;
        esac
    fi
}

manage_firewall_port() {
    local action="$1"
    local port="$2"
    local proto="$3"
    local comment="$4"
    local fw_type
    fw_type=$(detect_firewall)

    local protos=()
    if [[ "$proto" == "tcp/udp" || "$proto" == "both" ]]; then
        protos=("tcp" "udp")
    else
        protos=("$proto")
    fi

    case "$fw_type" in
        ufw)
            for p in "${protos[@]}"; do
                if [[ "$action" == "add" ]]; then
                    ufw allow "$port/$p" comment "$comment" >/dev/null 2>&1
                fi
            done
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            for p in "${protos[@]}"; do
                if [[ "$action" == "add" ]]; then
                    firewall-cmd --permanent --add-port="${port}/${p}" >/dev/null 2>&1
                fi
            done
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        iptables)
            for p in "${protos[@]}"; do
                if [[ "$action" == "add" ]]; then
                    iptables -A INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null
                fi
            done
            ;;
    esac
}

REALITY_CANDIDATES=(
    "gateway.icloud.com"
    "icloud.com"
    "www.microsoft.com"
    "microsoft.com"
    "dl.google.com"
    "speed.cloudflare.com"
)

select_best_domain_from_list() {
    local fallback="$1"
    shift
    local candidates=("$@")
    local best_domain="$fallback"
    local temp_file="/tmp/yindun_custom_domain_test.log"
    > "$temp_file"

    for domain in "${candidates[@]}"; do
        local time_cost
        time_cost=$(curl -o /dev/null -s -w "%{time_connect}" --max-time 2 "https://${domain}" 2>/dev/null)
        if [[ -n "$time_cost" ]] && awk "BEGIN {exit !($time_cost > 0)}"; then
            local ms
            ms=$(awk "BEGIN {print int($time_cost * 1000)}")
            echo "$ms $domain" >> "$temp_file"
        fi
    done

    if [ -s "$temp_file" ]; then
        best_domain=$(sort -n "$temp_file" | head -n 1 | awk '{print $2}')
    fi
    rm -f "$temp_file"
    echo -n "$best_domain"
}

select_best_reality_domain() {
    select_best_domain_from_list "gateway.icloud.com" "${REALITY_CANDIDATES[@]}"
}

# 公共全局增量写入函数：读取现有配置，过滤掉同名字段，安全合并追加，绝不覆盖其他协议
safe_append_listener() {
    local node_name="$1"
    local json_item_payload="$2"
    python3 - "$CONFIG_FILE" "$node_name" "$json_item_payload" << 'PY_EOF'
import sys, os, yaml, json
config_path, node_name, payload = sys.argv[1:4]
new_listener = json.loads(payload)

data = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            loaded = yaml.safe_load(f)
            if isinstance(loaded, dict):
                data = loaded
    except: pass

listeners = data.get("listeners", [])
if not isinstance(listeners, list):
    listeners = []

# 全局增量过滤：剔除同名旧节点，保留其他所有协议节点
listeners = [l for l in listeners if isinstance(l, dict) and l.get("name") != node_name]
listeners.append(new_listener)
data["listeners"] = listeners

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
PY_EOF
}

# 1. VLESS-REALITY
add_vless_reality_server_config() {
    check_and_install_python
    local host_name=$(hostname)

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入要指定的端口 [20000-60000]: " manual_port

    local port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    local short_id=$(openssl rand -hex 8 2>/dev/null | tr -d '\r\n')

    local mihomo_bin="${CONFIG_DIR}/mihomo"
    [ ! -x "$mihomo_bin" ] && echo -e "${RED}[ERROR] 未找到 Mihomo 可执行文件！${NC}" && return 1

    local keypair=$("$mihomo_bin" generate reality-keypair 2>/dev/null)
    local private_key=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}' | tr -d '\r\n')
    local public_key=$(echo "$keypair" | awk '/PublicKey:/ {print $2}' | tr -d '\r\n')
    [[ -z "$private_key" ]] && return 1

    local server_name=$(select_best_reality_domain)
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "tcp" "YinDun-Reality-${port}"
    local node_name="vless-reality-vision-in-${host_name}"
    local db_record="TYPE=vless-reality|NAME=${node_name}|PORT=${port}|UUID=${uuid}|PRIV=${private_key}|PUB=${public_key}|SHORTID=${short_id}|DOMAIN=${server_name}|IP=${server_ip}"

    python3 - "$NODES_DB" "$db_record" << 'PY_EOF'
import sys, os
nodes_db, db_record = sys.argv[1:3]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=vless-reality|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    local payload=$(python3 -c "import json; print(json.dumps({
        'name': '${node_name}', 'type': 'vless', 'port': int(${port}), 'listen': '0.0.0.0',
        'users': [{'username': '1', 'uuid': '${uuid}', 'flow': 'xtls-rprx-vision'}],
        'tls': True, 'server-name': '${server_name}',
        'reality': {'enabled': True, 'pubkey': '${public_key}', 'privkey': '${private_key}', 'short-id': ['${short_id}']}
    }))")
    safe_append_listener "$node_name" "$payload"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] VLESS-REALITY 服务端入站配置完成！${NC}"
}

# 2. Hysteria 2
add_hysteria2_server_config() {
    check_and_install_python
    check_and_install_dependencies
    local host_name=$(hostname)

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入 UDP 端口: " manual_port

    local port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local hy2_password=$(openssl rand -hex 12 2>/dev/null | tr -d '\r\n')
    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local cert_file="${cert_dir}/hy2.crt" key_file="${cert_dir}/hy2.key" sni_domain="gateway.icloud.com"

    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni_domain}" 2>/dev/null
    local sha256_fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" | cut -d '=' -f 2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "udp" "YinDun-Hy2-${port}"
    local node_name="hysteria2-in-${host_name}"
    local db_record="TYPE=hysteria2|NAME=${node_name}|PORT=${port}|PASSWORD=${hy2_password}|FINGERPRINT=${sha256_fingerprint}|SNI=${sni_domain}|IP=${server_ip}"

    python3 - "$NODES_DB" "$db_record" << 'PY_EOF'
import sys, os
nodes_db, db_record = sys.argv[1:3]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=hysteria2|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    local payload=$(python3 -c "import json; print(json.dumps({
        'name': '${node_name}', 'type': 'hysteria2', 'port': int(${port}), 'listen': '0.0.0.0',
        'up': '100 Mbps', 'down': '100 Mbps', 'users': [{'password': '${hy2_password}'}], 'tls': {'enabled': True}
    }))")
    safe_append_listener "$node_name" "$payload"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] Hysteria 2 服务端入站配置完成！${NC}"
}

# 3. TUIC v5
add_tuic_server_config() {
    check_and_install_python
    check_and_install_dependencies
    local host_name=$(hostname)

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入 UDP 端口: " manual_port

    local port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local tuic_uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    local tuic_password=$(openssl rand -hex 12 2>/dev/null | tr -d '\r\n')
    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local cert_file="${cert_dir}/tuic.crt" key_file="${cert_dir}/tuic.key" sni_domain="www.apple.com"

    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni_domain}" 2>/dev/null
    local sha256_fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" | cut -d '=' -f 2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "udp" "YinDun-Tuic-${port}"
    local node_name="tuic-in-${host_name}"
    local db_record="TYPE=tuic|NAME=${node_name}|PORT=${port}|UUID=${tuic_uuid}|PASSWORD=${tuic_password}|FINGERPRINT=${sha256_fingerprint}|SNI=${sni_domain}|IP=${server_ip}"

    python3 - "$NODES_DB" "$db_record" << 'PY_EOF'
import sys, os
nodes_db, db_record = sys.argv[1:3]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=tuic|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    local payload=$(python3 -c "import json; print(json.dumps({
        'name': '${node_name}', 'type': 'tuic', 'port': int(${port}), 'listen': '0.0.0.0',
        'users': [{'uuid': '${tuic_uuid}', 'password': '${tuic_password}'}], 'congestion-control': 'bbr', 'tls': {'enabled': True}
    }))")
    safe_append_listener "$node_name" "$payload"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] TUIC v5 服务端入站配置完成！${NC}"
}

# 4. Mieru
add_mieru_server_config() {
    check_and_install_python
    check_and_install_dependencies
    local host_name=$(hostname)

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_tcp="" manual_udp=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "TCP 端口: " manual_tcp && read -p "UDP 端口: " manual_udp

    local tcp_port=$(get_available_port "$port_mode" "$manual_tcp")
    local udp_port=$(get_available_port "$port_mode" "$manual_udp")
    [[ -z "$tcp_port" || -z "$udp_port" ]] && return 1

    local t_user="user_$(openssl rand -hex 3)" t_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local u_user="user_$(openssl rand -hex 3)" u_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$tcp_port" "tcp" "YinDun-Mieru-TCP-${tcp_port}"
    manage_firewall_port "add" "$udp_port" "udp" "YinDun-Mieru-UDP-${udp_port}"

    local t_name="mieru-tcp-in-${host_name}" u_name="mieru-udp-in-${host_name}"
    local rec_t="TYPE=mieru-tcp|NAME=${t_name}|PORT=${tcp_port}|USER=${t_user}|PASS=${t_pass}|IP=${server_ip}"
    local rec_u="TYPE=mieru-udp|NAME=${u_name}|PORT=${udp_port}|USER=${u_user}|PASS=${u_pass}|IP=${server_ip}"

    python3 - "$NODES_DB" "$rec_t" "$rec_u" << 'PY_EOF'
import sys, os
nodes_db, rec_t, rec_u = sys.argv[1:4]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=mieru-tcp|") and not l.startswith("TYPE=mieru-udp|")] if os.path.exists(nodes_db) else []
existing.extend([rec_t, rec_u])
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    safe_append_listener "$t_name" "$(python3 -c "import json; print(json.dumps({'name': '${t_name}', 'type': 'mieru', 'port': int(${tcp_port}), 'listen': '0.0.0.0', 'transport': 'TCP', 'users': { '${t_user}': '${t_pass}' }}))")"
    safe_append_listener "$u_name" "$(python3 -c "import json; print(json.dumps({'name': '${u_name}', 'type': 'mieru', 'port': int(${udp_port}), 'listen': '0.0.0.0', 'transport': 'UDP', 'users': { '${u_user}': '${u_pass}' }}))")"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] Mieru (TCP & UDP) 服务端入站配置完成！${NC}"
}

# 5. Snell v6
add_snell_server_config() {
    check_and_install_python
    check_and_install_dependencies
    local host_name=$(hostname)

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入端口: " manual_port

    local port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    read -p "请选择 Snell v6 模式 [1. default 2. unshaped] (默认 1): " mode_choice
    local snell_mode="default"
    [[ "$mode_choice" == "2" ]] && snell_mode="unshaped"

    local snell_psk=$(openssl rand -hex 16 2>/dev/null | tr -d '\r\n')
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "tcp" "YinDun-Snell-${port}"
    local node_name="snell-in-${host_name}"
    local db_record="TYPE=snell|NAME=${node_name}|PORT=${port}|PSK=${snell_psk}|VERSION=6|MODE=${snell_mode}|IP=${server_ip}"

    python3 - "$NODES_DB" "$db_record" << 'PY_EOF'
import sys, os
nodes_db, db_record = sys.argv[1:3]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=snell|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    local payload=$(python3 -c "import json; print(json.dumps({
        'name': '${node_name}', 'type': 'snell', 'port': int(${port}), 'listen': '0.0.0.0',
        'psk': '${snell_psk}', 'version': 6, 'udp': True, 'mode': '${snell_mode}'
    }))")
    safe_append_listener "$node_name" "$payload"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] Snell v6 原生入站配置已写入并重启！${NC}"
}

# 6. ShadowQUIC
add_shadowquic_server_config() {
    check_and_install_python
    check_and_install_dependencies
    local host_name=$(hostname)

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入 UDP 端口: " manual_port

    local port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local sq_user="user_$(openssl rand -hex 3)"
    local sq_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local best_domain=$(select_best_reality_domain)
    local jls_addr="${best_domain}:443"
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "udp" "YinDun-ShadowQUIC-${port}"
    local node_name="shadowquic-in-${host_name}"
    local db_record="TYPE=shadowquic|NAME=${node_name}|PORT=${port}|USER=${sq_user}|PASS=${sq_pass}|JLS=${jls_addr}|IP=${server_ip}"

    python3 - "$NODES_DB" "$db_record" << 'PY_EOF'
import sys, os
nodes_db, db_record = sys.argv[1:3]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=shadowquic|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    local payload=$(python3 -c "import json; print(json.dumps({
        'name': '${node_name}', 'type': 'shadowquic', 'port': int(${port}), 'listen': '0.0.0.0',
        'users': [{'username': '${sq_user}', 'password': '${sq_pass}'}], 'jls-upstream': {'addr': '${jls_addr}'}, 'congestion-controller': 'bbr'
    }))")
    safe_append_listener "$node_name" "$payload"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] ShadowQUIC 服务端入站配置完成！${NC}"
}

# 7. AnyTLS 四大模式
add_anytls_all_modes_server_config() {
    check_and_install_python
    check_and_install_dependencies
    local host_name=$(hostname)

    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local cert_file="${cert_dir}/anytls.crt" key_file="${cert_dir}/anytls.key"
    [ ! -f "$cert_file" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=download.nvidia.com" 2>/dev/null

    local stls_domain=$(select_best_domain_from_list "download.nvidia.com" "download.nvidia.com" "swcdn.apple.com")
    local rtls_domain=$(select_best_domain_from_list "cdn.akamai.steamstatic.com" "cdn.akamai.steamstatic.com" "launcher.store.epicgames.com")
    local jls_domain=$(select_best_domain_from_list "update.code.visualstudio.com" "update.code.visualstudio.com" "registry.npmjs.org")
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    local p_std=$(get_available_port "auto" "")
    local p_stls=$(get_available_port "auto" "")
    local p_rtls=$(get_available_port "auto" "")
    local p_jls=$(get_available_port "auto" "")

    manage_firewall_port "add" "$p_std" "tcp" "YinDun-AnyTLS-Standard-${p_std}"
    manage_firewall_port "add" "$p_stls" "tcp" "YinDun-AnyTLS-ShadowTLS-${p_stls}"
    manage_firewall_port "add" "$p_rtls" "tcp" "YinDun-AnyTLS-ResTLS-${p_rtls}"
    manage_firewall_port "add" "$p_jls" "tcp" "YinDun-AnyTLS-JLS-${p_jls}"

    local u_std="user_$(openssl rand -hex 3)" pass_std="$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    local u_stls="user_$(openssl rand -hex 3)" pass_stls="$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    local u_rtls="user_$(openssl rand -hex 3)" pass_rtls="$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    local u_jls="user_$(openssl rand -hex 3)" pass_jls="$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 12)"

    local name_std="anytls-standard-in-${host_name}"
    local name_stls="anytls-shadowtls-in-${host_name}"
    local name_rtls="anytls-restls-in-${host_name}"
    local name_jls="anytls-jls-in-${host_name}"

    local rec_std="TYPE=anytls|MODE=standard|NAME=${name_std}|PORT=${p_std}|USER=${u_std}|PASS=${pass_std}|IP=${server_ip}"
    local rec_stls="TYPE=anytls|MODE=shadowtls|NAME=${name_stls}|PORT=${p_stls}|USER=${u_stls}|PASS=${pass_stls}|DEST=${stls_domain}:443|IP=${server_ip}"
    local rec_rtls="TYPE=anytls|MODE=restls|NAME=${name_rtls}|PORT=${p_rtls}|USER=${u_rtls}|PASS=${pass_rtls}|DEST=${rtls_domain}:443|IP=${server_ip}"
    local rec_jls="TYPE=anytls|MODE=jls|NAME=${name_jls}|PORT=${p_jls}|USER=${u_jls}|PASS=${pass_jls}|DEST=${jls_domain}:443|SNI=${jls_domain}|IP=${server_ip}"

    python3 - "$NODES_DB" "$rec_std" "$rec_stls" "$rec_rtls" "$rec_jls" << 'PY_EOF'
import sys, os
nodes_db = sys.argv[1]
new_records = sys.argv[2:]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and "TYPE=anytls" not in l] if os.path.exists(nodes_db) else []
existing.extend(new_records)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    safe_append_listener "$name_std" "$(python3 -c "import json; print(json.dumps({'name': '${name_std}', 'type': 'anytls', 'port': int(${p_std}), 'listen': '0.0.0.0', 'users': {'${u_std}': '${pass_std}'}, 'certificate': '${cert_file}', 'private-key': '${key_file}'}))")"
    safe_append_listener "$name_stls" "$(python3 -c "import json; print(json.dumps({'name': '${name_stls}', 'type': 'anytls', 'port': int(${p_stls}), 'listen': '0.0.0.0', 'users': {'${u_stls}': '${pass_stls}'}, 'shadow-tls': {'enable': True, 'version': 3, 'users': [{'name': '${u_stls}', 'password': '${pass_stls}'}], 'handshake': {'dest': '${stls_domain}:443'}}}))")"
    safe_append_listener "$name_rtls" "$(python3 -c "import json; print(json.dumps({'name': '${name_rtls}', 'type': 'anytls', 'port': int(${p_rtls}), 'listen': '0.0.0.0', 'users': {'${u_rtls}': '${pass_rtls}'}, 'res-tls': {'enable': True, 'dest': '${rtls_domain}:443', 'password': '${pass_rtls}'}}))")"
    safe_append_listener "$name_jls" "$(python3 -c "import json; print(json.dumps({'name': '${name_jls}', 'type': 'anytls', 'port': int(${p_jls}), 'listen': '0.0.0.0', 'users': {'${u_jls}': '${pass_jls}'}, 'jls-config': {'enable': True, 'users': [{'username': '${u_jls}', 'password': '${pass_jls}'}], 'dest': '${jls_domain}:443', 'sni': '${jls_domain}'}}))")"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] AnyTLS 四大模式服务端入站配置完成！${NC}"
}

# 8. XHTTP 系列节点
add_xhttp_all_modes_server_config() {
    check_and_install_python
    check_and_install_dependencies
    local host_name=$(hostname)

    local mihomo_bin="${CONFIG_DIR}/mihomo"
    [ ! -x "$mihomo_bin" ] && return 1

    local x_dom_reality=$(select_best_domain_from_list "gateway.icloud.com" "gateway.icloud.com" "dl.google.com")
    local x_dom_stls=$(select_best_domain_from_list "download.nvidia.com" "download.nvidia.com" "swcdn.apple.com")
    local x_dom_rtls=$(select_best_domain_from_list "cdn.akamai.steamstatic.com" "cdn.akamai.steamstatic.com" "launcher.store.epicgames.com")
    local x_dom_jls=$(select_best_domain_from_list "update.code.visualstudio.com" "update.code.visualstudio.com" "registry.npmjs.org")
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "45.207.156.146")

    local p_xr=$(get_available_port "auto" "")
    local p_xst=$(get_available_port "auto" "")
    local p_xrt=$(get_available_port "auto" "")
    local p_xj=$(get_available_port "auto" "")

    manage_firewall_port "add" "$p_xr" "tcp" "YinDun-XHTTP-Reality-${p_xr}"
    manage_firewall_port "add" "$p_xst" "tcp" "YinDun-XHTTP-ShadowTLS-${p_xst}"
    manage_firewall_port "add" "$p_xrt" "tcp" "YinDun-XHTTP-ResTLS-${p_xrt}"
    manage_firewall_port "add" "$p_xj" "tcp" "YinDun-XHTTP-JLS-${p_xj}"

    local kp_xr=$("$mihomo_bin" generate reality-keypair 2>/dev/null)
    local priv_xr=$(echo "$kp_xr" | awk '/PrivateKey:/ {print $2}' | tr -d '\r\n')
    local pub_xr=$(echo "$kp_xr" | awk '/PublicKey:/ {print $2}' | tr -d '\r\n')
    local sid_xr=$(openssl rand -hex 8 2>/dev/null | tr -d '\r\n')

    local uuid_base=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    local uuid_stls=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    local uuid_rtls=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    local uuid_jls=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')

    local stls_pass=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 12)
    local restls_pass=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 12)
    local jls_pass=$(openssl rand -base64 10 | tr -dc 'a-zA-Z0-9' | head -c 12)

    local name_xr="xhttp-reality-in-${host_name}"
    local name_xst="xhttp-shadowtls-in-${host_name}"
    local name_xrt="xhttp-restls-in-${host_name}"
    local name_xj="xhttp-jls-in-${host_name}"

    local r_xr="TYPE=xhttp-reality|NAME=${name_xr}|PORT=${p_xr}|UUID=${uuid_base}|PRIV=${priv_xr}|PUB=${pub_xr}|SHORTID=${sid_xr}|DOMAIN=${x_dom_reality}|IP=${server_ip}"
    local r_xst="TYPE=xhttp-shadowtls|NAME=${name_xst}|PORT=${p_xst}|UUID=${uuid_stls}|PASS=${stls_pass}|DEST=${x_dom_stls}:443|IP=${server_ip}"
    local r_xrt="TYPE=xhttp-restls|NAME=${name_xrt}|PORT=${p_xrt}|UUID=${uuid_rtls}|PASS=${restls_pass}|DEST=${x_dom_rtls}:443|IP=${server_ip}"
    local r_xj="TYPE=xhttp-jls|NAME=${name_xj}|PORT=${p_xj}|UUID=${uuid_jls}|PASS=${jls_pass}|DEST=${x_dom_jls}:443|SNI=${x_dom_jls}|IP=${server_ip}"

    python3 - "$NODES_DB" "$r_xr" "$r_xst" "$r_xrt" "$r_xj" << 'PY_EOF'
import sys, os
nodes_db = sys.argv[1]
new_records = sys.argv[2:]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not any(t in l for t in ["TYPE=xhttp-reality", "TYPE=xhttp-shadowtls", "TYPE=xhttp-restls", "TYPE=xhttp-jls"])] if os.path.exists(nodes_db) else []
existing.extend(new_records)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF

    safe_append_listener "$name_xr" "$(python3 -c "import json; print(json.dumps({'name': '${name_xr}', 'type': 'vless', 'port': int(${p_xr}), 'listen': '0.0.0.0', 'users': [{'username': '1', 'uuid': '${uuid_base}', 'flow': ''}], 'xhttp-config': {'path': '/yindun-xr', 'host': '${x_dom_reality}', 'mode': 'stream-up', 'uplink-http-method': 'POST'}, 'reality-config': {'dest': '${x_dom_reality}:443', 'private-key': '${priv_xr}', 'short-id': ['${sid_xr}'], 'server-names': ['${x_dom_reality}']}}))")"
    safe_append_listener "$name_xst" "$(python3 -c "import json; print(json.dumps({'name': '${name_xst}', 'type': 'vless', 'port': int(${p_xst}), 'listen': '0.0.0.0', 'users': [{'username': '1', 'uuid': '${uuid_stls}', 'flow': ''}], 'xhttp-config': {'path': '/yindun-xst', 'host': '${x_dom_stls}', 'mode': 'stream-up', 'uplink-http-method': 'POST'}, 'shadow-tls': {'enable': True, 'version': 3, 'users': [{'name': '1', 'password': '${stls_pass}'}], 'handshake': {'dest': '${x_dom_stls}:443'}}}))")"
    safe_append_listener "$name_xrt" "$(python3 -c "import json; print(json.dumps({'name': '${name_xrt}', 'type': 'vless', 'port': int(${p_xrt}), 'listen': '0.0.0.0', 'users': [{'username': '1', 'uuid': '${uuid_rtls}', 'flow': ''}], 'xhttp-config': {'path': '/yindun-xrt', 'host': '${x_dom_rtls}', 'mode': 'stream-up', 'uplink-http-method': 'POST'}, 'res-tls': {'enable': True, 'dest': '${x_dom_rtls}:443', 'password': '${restls_pass}'}}))")"
    safe_append_listener "$name_xj" "$(python3 -c "import json; print(json.dumps({'name': '${name_xj}', 'type': 'vless', 'port': int(${p_xj}), 'listen': '0.0.0.0', 'users': [{'username': '1', 'uuid': '${uuid_jls}', 'flow': ''}], 'xhttp-config': {'path': '/yindun-xj', 'host': '${x_dom_jls}', 'mode': 'stream-up', 'uplink-http-method': 'POST'}, 'jls-config': {'enable': True, 'users': [{'username': '1', 'password': '${jls_pass}'}], 'dest': '${x_dom_jls}:443', 'sni': '${x_dom_jls}'}}))")"

    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] XHTTP 4大变体服务端入站配置已全部写入并成功重启！${NC}"
}

# 9. Argo 纯净 443 TLS 隧道（平铺结构）
launch_argo_tunnel() {
    local p_wstls="$1"
    local cf_bin="${CONFIG_DIR}/cloudflared"
    local log_wstls="${CONFIG_DIR}/argo_wstls.log"
    local pid_wstls="${CONFIG_DIR}/argo_wstls.pid"

    [ -f "$pid_wstls" ] && kill -9 "$(cat "$pid_wstls")" 2>/dev/null && rm -f "$pid_wstls"
    > "$log_wstls"

    nohup "$cf_bin" tunnel --url "https://127.0.0.1:${p_wstls}" --no-tls-verify --no-autoupdate > "$log_wstls" 2>&1 &
    echo $! > "$pid_wstls"

    local dom_wstls=""
    for _ in $(seq 1 20); do
        sleep 1
        dom_wstls=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log_wstls" 2>/dev/null | head -n 1 | sed 's|https://||')
        [[ -n "$dom_wstls" ]] && break
    done

    [[ -z "$dom_wstls" ]] && return 1
    ARGO_DOMAIN_WSTLS="$dom_wstls"
    return 0
}

add_argo_ws_server_config() {
    check_and_install_python
    check_and_install_dependencies
    check_and_install_cloudflared || return 1
    local host_name=$(hostname)

    local p_wstls=$(get_available_port "auto" "")
    local uuid_wstls="08bee351-4b23-4a78-a23c-b78143286f5d"
    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local argo_crt="${cert_dir}/argo_wstls.crt"
    local argo_key="${cert_dir}/argo_wstls.key"
    [ ! -f "$argo_crt" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout "$argo_key" -out "$argo_crt" -days 3650 -subj "/CN=argo.trycloudflare.com" 2>/dev/null

    local node_name="argo-wstls-in-${host_name}"
    manage_firewall_port "add" "$p_wstls" "tcp" "YinDun-Argo-${p_wstls}"

    local payload=$(python3 -c "import json; print(json.dumps({
        'name': '${node_name}', 'type': 'vless', 'port': int(${p_wstls}), 'listen': '127.0.0.1',
        'users': [{'username': '1', 'uuid': '${uuid_wstls}', 'flow': ''}],
        'ws-path': '/yindun-argo-wstls', 'certificate': '${argo_crt}', 'private-key': '${argo_key}'
    }))")
    safe_append_listener "$node_name" "$payload"

    systemctl restart mihomo
    sleep 1
    launch_argo_tunnel "$p_wstls" || return 1

    local r_wstls="TYPE=argo-wstls|NAME=${node_name}|PORT=${p_wstls}|UUID=${uuid_wstls}|DOMAIN=${ARGO_DOMAIN_WSTLS}|PATH=/yindun-argo-wstls"
    python3 - "$NODES_DB" "$r_wstls" << 'PY_EOF'
import sys, os
nodes_db, r_wstls = sys.argv[1:3]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=argo-ws|") and not l.startswith("TYPE=argo-wstls|")] if os.path.exists(nodes_db) else []
existing.append(r_wstls)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
PY_EOF
    echo -e "${GREEN}[SUCCESS] Argo 443 纯净 TLS 隧道节点配置成功！${NC}"
}

# 10. 一键自动化部署 1~9 号全套协议
install_all_protocols() {
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}      开始一键自动化部署 1 ~ 9 号全套代理协议集群...     ${NC}"
    echo -e "${CYAN}========================================================${NC}"
    
    add_vless_reality_server_config
    add_hysteria2_server_config
    add_tuic_server_config
    add_mieru_server_config
    add_snell_server_config
    add_shadowquic_server_config
    add_anytls_all_modes_server_config
    add_xhttp_all_modes_server_config
    add_argo_ws_server_config

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${GREEN}       🎉 恭喜！1 ~ 9 号所有协议已全部一键部署完毕！      ${NC}"
    echo -e "${GREEN}========================================================${NC}"
}

reload_argo_internal() {
    [ ! -f "$NODES_DB" ] && return 1
    local p_wstls=$(grep "^TYPE=argo-wstls|" "$NODES_DB" | grep -oP 'PORT=\K[^|]+' | head -n 1)
    [[ -z "$p_wstls" ]] && return 1
    check_and_install_cloudflared || return 1
    systemctl restart mihomo
    sleep 1
    launch_argo_tunnel "$p_wstls" || return 1

    python3 - "$NODES_DB" "$ARGO_DOMAIN_WSTLS" << 'PY_EOF'
import sys
nodes_db, new_dom_wstls = sys.argv[1:3]
lines = []
with open(nodes_db, encoding="utf-8") as f:
    for line in f:
        l = line.strip()
        if not l: continue
        if l.startswith("TYPE=argo-wstls|"):
            parts = [p if not p.startswith("DOMAIN=") else f"DOMAIN={new_dom_wstls}" for p in l.split("|")]
            l = "|".join(parts)
        lines.append(l)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(lines) + "\n")
PY_EOF
}

show_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================================${NC}"
        echo -e "${GREEN}        YinDun Server Node Configuration Menu          ${NC}"
        echo -e "${CYAN}========================================================${NC}"
        echo "1. 添加 VLESS-REALITY 服务端节点"
        echo "2. 添加 Hysteria 2 服务端节点"
        echo "3. 添加 TUIC v5 服务端节点"
        echo "4. 添加 Mieru (TCP & UDP) 服务端节点"
        echo "5. Snell v6 服务端节点"
        echo "6. 添加 ShadowQUIC 服务端节点"
        echo "7. 添加 AnyTLS 四大模式服务端节点"
        echo "8. XHTTP 4大变体服务端节点"
        echo "9. 添加/重置 Argo 纯净 443 TLS 隧道节点"
        echo "10. 一键自动安装并配置所有 1~9 号协议"
        echo "0. 退出脚本"
        echo -e "${CYAN}========================================================${NC}"
        read -p "请选择操作 [0-10]: " choice

        case "$choice" in
            1) add_vless_reality_server_config ;;
            2) add_hysteria2_server_config ;;
            3) add_tuic_server_config ;;
            4) add_mieru_server_config ;;
            5) add_snell_server_config ;;
            6) add_shadowquic_server_config ;;
            7) add_anytls_all_modes_server_config ;;
            8) add_xhttp_all_modes_server_config ;;
            9) add_argo_ws_server_config ;;
            10) install_all_protocols ;;
            0) echo -e "${GREEN}退出配置菜单。${NC}"; exit 0 ;;
            *) echo -e "${RED}[ERROR] 无效的选择！${NC}" ;;
        esac

        echo -e "\n${YELLOW}--------------------------------------------------------${NC}"
        read -p "当前操作已完成。按回车键继续返回多协议配置菜单..." _pause
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$1" == "reload-argo" ]]; then
        reload_argo_internal
    else
        show_menu
    fi
fi
