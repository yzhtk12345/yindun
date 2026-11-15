#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Configuration Manager (config.sh)
# Description: 支持 VLESS-REALITY、Hysteria 2、TUIC v5、Mieru 与 Snell 原生入站管理
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
            apt-get update -y && apt-get install -y iproute2 openssl &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y iproute openssl &>/dev/null
        fi
    fi
}

check_and_install_python() {
    if ! command -v python3 &>/dev/null || ! python3 -c "import yaml" &>/dev/null; then
        echo -e "${YELLOW}[INFO] 检测到系统缺少 Python 3 或 PyYAML，正在自动安装...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y python3 python3-yaml &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y python3 python3-PyYAML &>/dev/null
        fi
    fi
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
    echo -e "${CYAN}[INFO] 正在清理防火墙中的旧 ${target_type} 端口规则...${NC}"

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
                    echo -e "${GREEN}[UFW] 已开放端口 ${port}/${p} (备注: ${comment})${NC}"
                fi
            done
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            for p in "${protos[@]}"; do
                if [[ "$action" == "add" ]]; then
                    firewall-cmd --permanent --add-port="${port}/${p}" >/dev/null 2>&1
                    echo -e "${GREEN}[Firewalld] 已永久开放端口 ${port}/${p}${NC}"
                fi
            done
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        iptables)
            for p in "${protos[@]}"; do
                if [[ "$action" == "add" ]]; then
                    iptables -A INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null
                    echo -e "${GREEN}[Iptables] 已开放端口 ${port}/${p}${NC}"
                fi
            done
            ;;
        *)
            echo -e "${YELLOW}[WARN] 未检测到主流防火墙，跳过配置。${NC}"
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

select_best_reality_domain() {
    echo -e "${CYAN}[INFO] 正在对 REALITY 候选回落域名进行测速优选...${NC}" >&2
    local best_domain="gateway.icloud.com"
    local temp_file="/tmp/yindun_domain_test.log"
    > "$temp_file"

    for domain in "${REALITY_CANDIDATES[@]}"; do
        local time_cost
        time_cost=$(curl -o /dev/null -s -w "%{time_connect}" --max-time 2 "https://${domain}" 2>/dev/null)
        if [[ -n "$time_cost" ]] && awk "BEGIN {exit !($time_cost > 0)}"; then
            local ms
            ms=$(awk "BEGIN {print int($time_cost * 1000)}")
            echo -e "  -> 域名: ${domain} | 延迟: ${ms} ms" >&2
            echo "$ms $domain" >> "$temp_file"
        fi
    done

    if [ -s "$temp_file" ]; then
        best_domain=$(sort -n "$temp_file" | head -n 1 | awk '{print $2}')
        echo -e "${GREEN}[SUCCESS] 已自动选中最优域名: ${best_domain}${NC}" >&2
    else
        echo -e "${YELLOW}[WARN] 测速未完成，兜底使用: ${best_domain}${NC}" >&2
    fi
    rm -f "$temp_file"
    
    echo -n "$best_domain"
}

# 1. VLESS-REALITY
add_vless_reality_server_config() {
    check_and_install_python
    cleanup_firewall_by_type "vless-reality"
    local host_name
    host_name=$(hostname)

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}        开始配置并写入 VLESS-REALITY 服务端入站          ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto"
    local manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入要指定的端口 [20000-60000]: " manual_port

    local port
    port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local uuid short_id
    uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    short_id=$(openssl rand -hex 8 2>/dev/null | tr -d '\r\n')

    local mihomo_bin="${CONFIG_DIR}/mihomo"
    [ ! -x "$mihomo_bin" ] && echo -e "${RED}[ERROR] 未找到 Mihomo 可执行文件！${NC}" && return 1

    local keypair private_key public_key
    keypair=$("$mihomo_bin" generate reality-keypair 2>/dev/null)
    private_key=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}' | tr -d '\r\n')
    public_key=$(echo "$keypair" | awk '/PublicKey:/ {print $2}' | tr -d '\r\n')
    [[ -z "$private_key" ]] && return 1

    local server_name server_ip
    server_name=$(select_best_reality_domain)
    server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

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
    local host_name
    host_name=$(hostname)

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}        开始配置并写入 Hysteria 2 服务端入站             ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入 UDP 端口: " manual_port

    local port
    port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local hy2_password
    hy2_password=$(openssl rand -hex 12 2>/dev/null | tr -d '\r\n')
    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local cert_file="${cert_dir}/hy2.crt" key_file="${cert_dir}/hy2.key" sni_domain="gateway.icloud.com"

    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni_domain}" 2>/dev/null
    local sha256_fingerprint
    sha256_fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" | cut -d '=' -f 2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

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
    local host_name
    host_name=$(hostname)

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}        开始配置并写入 TUIC v5 服务端入站             ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入 UDP 端口: " manual_port

    local port
    port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local tuic_uuid tuic_password
    tuic_uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    tuic_password=$(openssl rand -hex 12 2>/dev/null | tr -d '\r\n')
    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local cert_file="${cert_dir}/tuic.crt" key_file="${cert_dir}/tuic.key" sni_domain="www.apple.com"

    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni_domain}" 2>/dev/null
    local sha256_fingerprint
    sha256_fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" | cut -d '=' -f 2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

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

# 4. Mieru (TCP & UDP)
add_mieru_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "mieru-tcp"
    cleanup_firewall_by_type "mieru-udp"
    local host_name
    host_name=$(hostname)

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}        开始配置并写入 Mieru (TCP & UDP) 服务端入站     ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_tcp="" manual_udp=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "TCP 端口: " manual_tcp && read -p "UDP 端口: " manual_udp

    local tcp_port udp_port
    tcp_port=$(get_available_port "$port_mode" "$manual_tcp")
    udp_port=$(get_available_port "$port_mode" "$manual_udp")
    [[ -z "$tcp_port" || -z "$udp_port" ]] && return 1

    local t_user="user_$(openssl rand -hex 3)" t_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local u_user="user_$(openssl rand -hex 3)" u_pass="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

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

# 5. Snell (Mihomo 原生入站)
add_snell_server_config() {
    check_and_install_python
    check_and_install_dependencies
    cleanup_firewall_by_type "snell"
    local host_name
    host_name=$(hostname)

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}        开始配置并写入 Snell (原生入站) 服务端入站        ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    read -p "请选择端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_mode_choice
    local port_mode="auto" manual_port=""
    [[ "$port_mode_choice" == "2" ]] && port_mode="manual" && read -p "请输入端口: " manual_port

    local port
    port=$(get_available_port "$port_mode" "$manual_port")
    [[ -z "$port" ]] && return 1

    local snell_psk
    snell_psk=$(openssl rand -hex 12 2>/dev/null | tr -d '\r\n')
    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "tcp" "YinDun-Snell-${port}"
    local node_name="snell-in-${host_name}"
    local db_record="TYPE=snell|NAME=${node_name}|PORT=${port}|PSK=${snell_psk}|IP=${server_ip}"

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

listeners.append({
    "name": node_name,
    "type": "snell",
    "port": port,
    "listen": "0.0.0.0",
    "psk": psk,
    "version": 4,
    "udp": True
})
blocks = ["\n".join("  " + l for l in yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip().splitlines()) for item in listeners]
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f: f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF
    systemctl restart mihomo
    echo -e "${GREEN}[SUCCESS] Snell 原生入站配置已写入并重启！${NC}"
    echo -e "入站标识 : ${YELLOW}${node_name}${NC}"
    echo -e "监听端口 : ${YELLOW}${port} (TCP)${NC}"
    echo -e "PSK 密码 : ${YELLOW}${snell_psk}${NC}"
    echo -e "协议版本 : ${YELLOW}v4 (UDP over TCP)${NC}"
}

show_menu() {
    clear
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}        YinDun Server Node Configuration Menu          ${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo "1. 添加 VLESS-REALITY 服务端节点"
    echo "2. 添加 Hysteria 2 服务端节点 (自签证书 + SHA-256 指纹)"
    echo "3. 添加 TUIC v5 服务端节点 (自签证书 + BBR + SNI 隔离)"
    echo "4. 添加 Mieru (TCP & UDP) 服务端节点"
    echo "5. 添加 Snell (Mihomo 原生入站 v4) 服务端节点"
    echo "0. 退出脚本"
    echo -e "${CYAN}========================================================${NC}"
    read -p "请选择操作 [0-5]: " choice

    case "$choice" in
        1) add_vless_reality_server_config ;;
        2) add_hysteria2_server_config ;;
        3) add_tuic_server_config ;;
        4) add_mieru_server_config ;;
        5) add_snell_server_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}[ERROR] 无效的选择！${NC}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_menu
fi
