#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Configuration Manager (config.sh)
# Description: 完整支持 VLESS-REALITY、Hysteria 2、TUIC v5、Mieru、Snell v6、ShadowQUIC、AnyTLS、XHTTP 及全新纯净 Argo 443 TLS 隧道的管理脚本
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
    local fw_type=$(detect_firewall)

    if [ -f "$NODES_DB" ]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if echo "$line" | grep -q "TYPE=${target_type}|"; then
                local old_p=$(echo "$line" | grep -oP 'PORT=\K[^|]+')
                if [[ -n "$old_p" ]]; then
                    case "$fw_type" in
                        ufw) ufw delete allow "${old_p}/tcp" >/dev/null 2>&1; ufw delete allow "${old_p}/udp" >/dev/null 2>&1 ;;
                        firewalld) firewall-cmd --permanent --remove-port="${old_p}/tcp" >/dev/null 2>&1; firewall-cmd --permanent --remove-port="${old_p}/udp" >/dev/null 2>&1 ;;
                        iptables) iptables -D INPUT -p tcp --dport "$old_p" -j ACCEPT 2>/dev/null || true; iptables -D INPUT -p udp --dport "$old_p" -j ACCEPT 2>/dev/null || true ;;
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
    local action="$1" port="$2" proto="$3" comment="$4" fw_type=$(detect_firewall)
    case "$fw_type" in
        ufw) [[ "$action" == "add" ]] && ufw allow "$port/$proto" comment "$comment" >/dev/null 2>&1 && ufw reload >/dev/null 2>&1 ;;
        firewalld) [[ "$action" == "add" ]] && firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 ;;
        iptables) [[ "$action" == "add" ]] && iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null ;;
    esac
}

REALITY_CANDIDATES=("gateway.icloud.com" "icloud.com" "www.microsoft.com" "dl.google.com")
select_best_domain_from_list() {
    local fallback="$1"
    shift
    local candidates=("$@")
    local best_domain="$fallback"
    local temp_file="/tmp/yindun_custom_domain_test.log"
    > "$temp_file"
    for domain in "${candidates[@]}"; do
        local time_cost=$(curl -o /dev/null -s -w "%{time_connect}" --max-time 2 "https://${domain}" 2>/dev/null)
        if [[ -n "$time_cost" ]] && awk "BEGIN {exit !($time_cost > 0)}"; then
            local ms=$(awk "BEGIN {print int($time_cost * 1000)}")
            echo "$ms $domain" >> "$temp_file"
        fi
    done
    [ -s "$temp_file" ] && best_domain=$(sort -n "$temp_file" | head -n 1 | awk '{print $2}')
    rm -f "$temp_file"
    echo -n "$best_domain"
}
select_best_reality_domain() { select_best_domain_from_list "gateway.icloud.com" "${REALITY_CANDIDATES[@]}"; }

# 1. VLESS-REALITY
add_vless_reality_server_config() {
    check_and_install_python
    cleanup_firewall_by_type "vless-reality"
    local host_name=$(hostname)
    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入要指定的端口: " manual_port
    local port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    local short_id=$(openssl rand -hex 8 2>/dev/null | tr -d '\r\n')
    local mihomo_bin="${CONFIG_DIR}/mihomo"
    [ ! -x "$mihomo_bin" ] && return 1

    local keypair=$("$mihomo_bin" generate reality-keypair 2>/dev/null)
    local private_key=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}' | tr -d '\r\n')
    local public_key=$(echo "$keypair" | awk '/PublicKey:/ {print $2}' | tr -d '\r\n')
    local server_name=$(select_best_reality_domain)
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "tcp" "YinDun-Reality-${port}"
    local node_name="vless-reality-vision-in-${host_name}"
    local db_record="TYPE=vless-reality|NAME=${node_name}|PORT=${port}|UUID=${uuid}|PRIV=${private_key}|PUB=${public_key}|SHORTID=${short_id}|DOMAIN=${server_name}|IP=${server_ip}"

    python3 - "$CONFIG_FILE" "$NODES_DB" "$node_name" "$port" "$db_record" "$uuid" "$server_name" "$private_key" "$short_id" << 'PY_EOF'
import sys, os, yaml
config_path, nodes_db, node_name, port_str, db_record, uuid, server_name, priv, short_id = sys.argv[1:10]
port = int(port_str)
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=vless-reality|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") != node_name]
    except: pass
listeners.append({
    "name": node_name, "type": "vless", "port": port, "listen": "0.0.0.0",
    "users": [{"username": "1", "uuid": uuid, "flow": "xtls-rprx-vision"}],
    "reality-config": {"dest": f"{server_name}:443", "private-key": priv, "short-id": [short_id], "server-names": [server_name]}
})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] VLESS-REALITY 服务端入站配置完成！${NC}"
}

# 2. Hysteria 2
add_hysteria2_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "hysteria2"
    local host_name=$(hostname)
    read -p "请输入 UDP 端口: " manual_port
    local port=$(get_available_port "manual" "$manual_port")
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

    python3 - "$CONFIG_FILE" "$NODES_DB" "$node_name" "$port" "$db_record" "$hy2_password" "$cert_file" "$key_file" << 'PY_EOF'
import sys, os, yaml
config_path, nodes_db, node_name, port_str, db_record, password, cert_file, key_file = sys.argv[1:9]
port = int(port_str)
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=hysteria2|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") != node_name]
    except: pass
listeners.append({
    "name": node_name, "type": "hysteria2", "port": port, "listen": "0.0.0.0",
    "users": {"1": password}, "alpn": ["h3"], "certificate": cert_file, "private-key": key_file
})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] Hysteria 2 服务端入站配置完成！${NC}"
}

# 3. TUIC v5
add_tuic_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "tuic"
    local host_name=$(hostname)
    read -p "请输入 UDP 端口: " manual_port
    local port=$(get_available_port "manual" "$manual_port")
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

    python3 - "$CONFIG_FILE" "$NODES_DB" "$node_name" "$port" "$db_record" "$tuic_uuid" "$tuic_password" "$cert_file" "$key_file" << 'PY_EOF'
import sys, os, yaml
config_path, nodes_db, node_name, port_str, db_record, tuic_uuid, password, cert_file, key_file = sys.argv[1:10]
port = int(port_str)
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=tuic|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") != node_name]
    except: pass
listeners.append({
    "name": node_name, "type": "tuic", "port": port, "listen": "0.0.0.0",
    "users": {tuic_uuid: password}, "congestion-controller": "bbr", "alpn": ["h3"],
    "certificate": cert_file, "private-key": key_file
})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] TUIC v5 服务端入站配置完成！${NC}"
}

# 4. Mieru
add_mieru_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "mieru-tcp"
    cleanup_firewall_by_type "mieru-udp"
    local host_name=$(hostname)
    read -p "TCP 端口: " manual_tcp && read -p "UDP 端口: " manual_udp
    local tcp_port=$(get_available_port "manual" "$manual_tcp")
    local udp_port=$(get_available_port "manual" "$manual_udp")
    [[ -z "$tcp_port" || -z "$udp_port" ]] && return 1

    local t_user="user_$(openssl rand -hex 3)" t_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local u_user="user_$(openssl rand -hex 3)" u_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$tcp_port" "tcp" "YinDun-Mieru-TCP-${tcp_port}"
    manage_firewall_port "add" "$udp_port" "udp" "YinDun-Mieru-UDP-${udp_port}"
    local t_name="mieru-tcp-in-${host_name}" u_name="mieru-udp-in-${host_name}"
    local rec_t="TYPE=mieru-tcp|NAME=${t_name}|PORT=${tcp_port}|USER=${t_user}|PASS=${t_pass}|IP=${server_ip}"
    local rec_u="TYPE=mieru-udp|NAME=${u_name}|PORT=${udp_port}|USER=${u_user}|PASS=${u_pass}|IP=${server_ip}"

    python3 - "$CONFIG_FILE" "$NODES_DB" "$t_name" "$tcp_port" "$t_user" "$t_pass" "$u_name" "$udp_port" "$u_user" "$u_pass" "$rec_t" "$rec_u" << 'PY_EOF'
import sys, os, yaml
config_path, nodes_db, t_name, t_port_s, t_user, t_pass, u_name, u_port_s, u_user, u_pass, rec_t, rec_u = sys.argv[1:13]
t_port, u_port = int(t_port_s), int(u_port_s)
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=mieru-tcp|") and not l.startswith("TYPE=mieru-udp|")] if os.path.exists(nodes_db) else []
existing.extend([rec_t, rec_u])
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") not in [t_name, u_name]]
    except: pass
listeners.append({"name": t_name, "type": "mieru", "port": t_port, "listen": "0.0.0.0", "transport": "TCP", "users": {t_user: t_pass}})
listeners.append({"name": u_name, "type": "mieru", "port": u_port, "listen": "0.0.0.0", "transport": "UDP", "users": {u_user: u_pass}})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] Mieru (TCP & UDP) 服务端入站配置完成！${NC}"
}

# 5. Snell v6
add_snell_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "snell"
    local host_name=$(hostname)
    read -p "请输入端口: " manual_port
    local port=$(get_available_port "manual" "$manual_port")
    [[ -z "$port" ]] && return 1

    local snell_psk=$(openssl rand -hex 16 2>/dev/null | tr -d '\r\n')
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")
    manage_firewall_port "add" "$port" "tcp" "YinDun-Snell-${port}"
    local node_name="snell-in-${host_name}"
    local db_record="TYPE=snell|NAME=${node_name}|PORT=${port}|PSK=${snell_psk}|VERSION=6|MODE=default|IP=${server_ip}"

    python3 - "$CONFIG_FILE" "$NODES_DB" "$node_name" "$port" "$snell_psk" "$db_record" << 'PY_EOF'
import sys, os, yaml
config_path, nodes_db, node_name, port_str, psk, db_record = sys.argv[1:7]
port = int(port_str)
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=snell|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") != node_name]
    except: pass
listeners.append({"name": node_name, "type": "snell", "port": port, "listen": "0.0.0.0", "psk": psk, "version": 6, "udp": True, "mode": "default"})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] Snell v6 原生入站配置已写入并重启！${NC}"
}

# 6. ShadowQUIC
add_shadowquic_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "shadowquic"
    local host_name=$(hostname)
    read -p "请输入 UDP 端口: " manual_port
    local port=$(get_available_port "manual" "$manual_port")
    [[ -z "$port" ]] && return 1

    local sq_user="user_$(openssl rand -hex 3)"
    local sq_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local best_domain=$(select_best_reality_domain)
    local jls_addr="${best_domain}:443"
    local server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "udp" "YinDun-ShadowQUIC-${port}"
    local node_name="shadowquic-in-${host_name}"
    local db_record="TYPE=shadowquic|NAME=${node_name}|PORT=${port}|USER=${sq_user}|PASS=${sq_pass}|JLS=${jls_addr}|IP=${server_ip}"

    python3 - "$CONFIG_FILE" "$NODES_DB" "$node_name" "$port" "$sq_user" "$sq_pass" "$jls_addr" "$db_record" << 'PY_EOF'
import sys, os, yaml
config_path, nodes_db, node_name, port_str, user, passwd, jls, db_record = sys.argv[1:9]
port = int(port_str)
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not l.startswith("TYPE=shadowquic|")] if os.path.exists(nodes_db) else []
existing.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") != node_name]
    except: pass
listeners.append({"name": node_name, "type": "shadowquic", "port": port, "listen": "0.0.0.0", "users": [{"username": user, "password": passwd}], "jls-upstream": {"addr": jls}, "congestion-controller": "bbr"})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] ShadowQUIC 服务端入站配置完成！${NC}"
}

# 7. AnyTLS 四大模式
add_anytls_all_modes_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "anytls"
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

    python3 - "$CONFIG_FILE" "$NODES_DB" \
        "$name_std" "$p_std" "$u_std" "$pass_std" "$cert_file" "$key_file" "$rec_std" \
        "$name_stls" "$p_stls" "$u_stls" "$pass_stls" "$stls_domain" "$rec_stls" \
        "$name_rtls" "$p_rtls" "$u_rtls" "$pass_rtls" "$rtls_domain" "$rec_rtls" \
        "$name_jls" "$p_jls" "$u_jls" "$pass_jls" "$jls_domain" "$rec_jls" << 'PY_EOF'
import sys, os, yaml
args = sys.argv[1:]
config_path, nodes_db = args[0], args[1]
n_std, p_std, u_std, pw_std, crt, key, rec_std = args[2:9]
n_stls, p_stls, u_stls, pw_stls, d_stls, rec_stls = args[9:15]
n_rtls, p_rtls, u_rtls, pw_rtls, d_rtls, rec_rtls = args[15:21]
n_jls, p_jls, u_jls, pw_jls, d_jls, rec_jls = args[21:27]
anytls_names = {n_std, n_stls, n_rtls, n_jls}
new_records = [rec_std, rec_stls, rec_rtls, rec_jls]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and "TYPE=anytls" not in l] if os.path.exists(nodes_db) else []
existing.extend(new_records)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") not in anytls_names]
    except: pass
listeners.append({"name": n_std, "type": "anytls", "port": int(p_std), "listen": "0.0.0.0", "users": {u_std: pw_std}, "certificate": crt, "private-key": key})
listeners.append({"name": n_stls, "type": "anytls", "port": int(p_stls), "listen": "0.0.0.0", "users": {u_stls: pw_stls}, "shadow-tls": {"enable": True, "version": 3, "users": [{"name": u_stls, "password": pw_stls}], "handshake": {"dest": f"{d_stls}:443"}}})
listeners.append({"name": n_rtls, "type": "anytls", "port": int(p_rtls), "listen": "0.0.0.0", "users": {u_rtls: pw_rtls}, "res-tls": {"enable": True, "dest": f"{d_rtls}:443", "password": pw_rtls}})
listeners.append({"name": n_jls, "type": "anytls", "port": int(p_jls), "listen": "0.0.0.0", "users": {u_jls: pw_jls}, "jls-config": {"enable": True, "users": [{"username": u_jls, "password": pw_jls}], "dest": f"{d_jls}:443", "sni": d_jls}})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] AnyTLS 四大模式服务端入站配置完成！${NC}"
}

# 8. XHTTP 系列节点
add_xhttp_all_modes_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "xhttp-reality"
    cleanup_firewall_by_type "xhttp-shadowtls"
    cleanup_firewall_by_type "xhttp-restls"
    cleanup_firewall_by_type "xhttp-jls"
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

    python3 - "$CONFIG_FILE" "$NODES_DB" \
        "$name_xr" "$p_xr" "$uuid_base" "$x_dom_reality" "$priv_xr" "$pub_xr" "$sid_xr" "$r_xr" \
        "$name_xst" "$p_xst" "$uuid_stls" "$stls_pass" "$x_dom_stls" "$r_xst" \
        "$name_xrt" "$p_xrt" "$uuid_rtls" "$restls_pass" "$x_dom_rtls" "$r_xrt" \
        "$name_xj" "$p_xj" "$uuid_jls" "$jls_pass" "$x_dom_jls" "$r_xj" << 'PY_EOF'
import sys, os, yaml
args = sys.argv[1:]
config_path, nodes_db = args[0], args[1]
n_xr, p_xr, u_xr, d_xr, priv, pub, sid, rec_xr = args[2:10]
n_xst, p_xst, u_xst, pw_stls, d_stls, rec_xst = args[10:16]
n_xrt, p_xrt, u_xrt, pw_rtls, d_rtls, rec_xrt = args[16:22]
n_xj, p_xj, u_xj, pw_jls, d_jls, rec_xj = args[22:28]
xhttp_names = {n_xr, n_xst, n_xrt, n_xj}
new_records = [rec_xr, rec_xst, rec_xrt, rec_xj]
existing = [l.strip() for l in open(nodes_db, encoding="utf-8") if l.strip() and not any(t in l for t in ["TYPE=xhttp-reality", "TYPE=xhttp-shadowtls", "TYPE=xhttp-restls", "TYPE=xhttp-jls"])] if os.path.exists(nodes_db) else []
existing.extend(new_records)
with open(nodes_db, "w", encoding="utf-8") as f: f.write("\n".join(existing) + "\n")
listeners = []
if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") not in xhttp_names]
    except: pass
listeners.append({"name": n_xr, "type": "vless", "port": int(p_xr), "listen": "0.0.0.0", "users": [{"username": "1", "uuid": u_xr, "flow": ""}], "xhttp-config": {"path": "/yindun-xr", "host": d_xr, "mode": "stream-up", "uplink-http-method": "POST"}, "reality-config": {"dest": f"{d_xr}:443", "private-key": priv, "short-id": [sid], "server-names": [d_xr]}})
listeners.append({"name": n_xst, "type": "vless", "port": int(p_xst), "listen": "0.0.0.0", "users": [{"username": "1", "uuid": u_xst, "flow": ""}], "xhttp-config": {"path": "/yindun-xst", "host": d_stls, "mode": "stream-up", "uplink-http-method": "POST"}, "shadow-tls": {"enable": True, "version": 3, "users": [{"name": "1", "password": pw_stls}], "handshake": {"dest": f"{d_stls}:443"}}})
listeners.append({"name": n_xrt, "type": "vless", "port": int(p_xrt), "listen": "0.0.0.0", "users": [{"username": "1", "uuid": u_xrt, "flow": ""}], "xhttp-config": {"path": "/yindun-xrt", "host": d_rtls, "mode": "stream-up", "uplink-http-method": "POST"}, "res-tls": {"enable": True, "dest": f"{d_rtls}:443", "password": pw_rtls}})
listeners.append({"name": n_xj, "type": "vless", "port": int(p_xj), "listen": "0.0.0.0", "users": [{"username": "1", "uuid": u_xj, "flow": ""}], "xhttp-config": {"path": "/yindun-xj", "host": d_jls, "mode": "stream-up", "uplink-http-method": "POST"}, "jls-config": {"enable": True, "users": [{"username": "1", "password": pw_jls}], "dest": f"{d_jls}:443", "sni": d_jls}})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] XHTTP 4大变体服务端入站配置已全部写入并成功重启！${NC}"
}

# 9. Argo 纯净 TLS 隧道核心逻辑（严格对齐你的字段平铺结构）
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
    check_and_install_cloudflared || return 1

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}  开始配置并写入 Argo 隧道 (argo-wstls-in-hk2t)        ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    local p_wstls="38187"
    read -p "请输入本地端口 [默认 38187]: " input_p
    [[ -n "$input_p" ]] && p_wstls="$input_p"

    local uuid_wstls="08bee351-4b23-4a78-a23c-b78143286f5d"
    read -p "是否随机生成新的 UUID？[y/N]: " gen_uuid_choice
    if [[ "$gen_uuid_choice" =~ ^[Yy]$ ]]; then
        uuid_wstls=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    fi

    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local argo_crt="${cert_dir}/argo_wstls.crt"
    local argo_key="${cert_dir}/argo_wstls.key"
    
    [ ! -f "$argo_crt" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout "$argo_key" -out "$argo_crt" -days 3650 -subj "/CN=argo.trycloudflare.com" 2>/dev/null

    local node_name="argo-wstls-in-hk2t"

    # 使用纯净平铺文本直写，完美匹配你的结构
    python3 - "$CONFIG_FILE" "$node_name" "$p_wstls" "$uuid_wstls" "$argo_crt" "$argo_key" << 'PY_EOF'
import sys, os, yaml

config_path, name, port, uuid, crt, key = sys.argv[1:7]
listeners = []

if os.path.exists(config_path):
    try:
        loaded = yaml.safe_load(open(config_path, encoding="utf-8"))
        if loaded and isinstance(loaded, dict) and "listeners" in loaded:
            listeners = [l for l in loaded["listeners"] if l.get("name") not in {name, "argo-ws-in-hk2t"}]
    except: pass

new_listener = {
    "name": name,
    "type": "vless",
    "port": int(port),
    "listen": "127.0.0.1",
    "users": [
        {
            "username": "1",
            "uuid": uuid,
            "flow": ""
        }
    ],
    "ws-path": "/yindun-argo-wstls",
    "certificate": crt,
    "private-key": key
}

listeners.append(new_listener)

with open(config_path, "w", encoding="utf-8") as f:
    f.write("listeners:\n")
    for item in listeners:
        f.write(f"  - name: {item['name']}\n")
        f.write(f"    type: {item['type']}\n")
        f.write(f"    port: {item['port']}\n")
        f.write(f"    listen: {item['listen']}\n")
        f.write(f"    users:\n")
        for u in item['users']:
            f.write(f"      - username: '{u['username']}'\n")
            f.write(f"        uuid: {u['uuid']}\n")
            f.write(f"        flow: '{u['flow']}'\n")
        f.write(f"    ws-path: \"{item['ws-path']}\"\n")
        f.write(f"    certificate: {item['certificate']}\n")
        f.write(f"    private-key: {item['private-key']}\n\n")
PY_EOF

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

    echo -e "${GREEN}[SUCCESS] Argo 纯净 443 隧道节点 (argo-wstls-in-hk2t) 配置成功！${NC}"
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
    clear
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}        YinDun Server Node Configuration Menu          ${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo "1. 添加 VLESS-REALITY 服务端节点"
    echo "2. 添加 Hysteria 2 服务端节点"
    echo "3. 添加 TUIC v5 服务端节点"
    echo "4. 添加 Mieru (TCP & UDP) 服务端节点"
    echo "5. 添加 Snell v6 服务端节点"
    echo "6. 添加 ShadowQUIC 服务端节点"
    echo "7. 添加 AnyTLS 四大模式服务端节点"
    echo "8. 添加 XHTTP 4大变体服务端节点"
    echo "9. 添加/重置 Argo 纯净 443 TLS 隧道 (argo-wstls-in-hk2t)"
    echo "0. 退出脚本"
    echo -e "${CYAN}========================================================${NC}"
    read -p "请选择操作 [0-9]: " choice

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
        0) exit 0 ;;
        *) echo -e "${RED}[ERROR] 无效的选择！${NC}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$1" == "reload-argo" ]]; then
        reload_argo_internal
    else
        show_menu
    fi
fi
