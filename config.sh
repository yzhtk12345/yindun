#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Configuration Manager (config.sh)
# Description: 支持 VLESS-REALITY 与 Hysteria 2 服务端入站管理（Git 本地直接执行版）
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

# ------------------------------------------------------------------------------
# VLESS-REALITY 服务端核心写入模块
# ------------------------------------------------------------------------------
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
    if [[ "$port_mode_choice" == "2" ]]; then
        port_mode="manual"
        read -p "请输入要指定的端口 [20000-60000]: " manual_port
    fi

    local port
    port=$(get_available_port "$port_mode" "$manual_port")
    if [[ -z "$port" ]]; then
        echo -e "${RED}[ERROR] 端口获取失败，取消操作。${NC}"
        return 1
    fi

    local uuid short_id
    uuid=$(cat /proc/sys/kernel/random/uuid | tr -d '\r\n')
    short_id=$(openssl rand -hex 8 2>/dev/null | tr -d '\r\n')

    local mihomo_bin="${CONFIG_DIR}/mihomo"
    if [ ! -x "$mihomo_bin" ]; then
        echo -e "${RED}[ERROR] 未找到 Mihomo 可执行文件 (${mihomo_bin})！${NC}"
        return 1
    fi

    echo -e "${CYAN}[INFO] 正在调用 mihomo 生成官方 Reality 密钥对...${NC}"
    local keypair private_key public_key
    keypair=$("$mihomo_bin" generate reality-keypair 2>/dev/null)
    
    private_key=$(echo "$keypair" | awk '/PrivateKey:/ {print $2}' | tr -d '\r\n')
    public_key=$(echo "$keypair" | awk '/PublicKey:/ {print $2}' | tr -d '\r\n')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        echo -e "${RED}[ERROR] 密钥对生成失败！${NC}"
        return 1
    fi

    local server_name
    server_name=$(select_best_reality_domain)
    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "tcp" "YinDun-Reality-${port}"

    local node_name="vless-reality-vision-in-${host_name}"
    local db_record="TYPE=vless-reality|NAME=${node_name}|PORT=${port}|UUID=${uuid}|PRIV=${private_key}|PUB=${public_key}|SHORTID=${short_id}|DOMAIN=${server_name}|IP=${server_ip}"

    # Python 安全写入：确保多协议独立区块并带有完美的空行
    python3 - "$CONFIG_FILE" "$NODES_DB" "$node_name" "$port" "$db_record" "$uuid" "$server_name" "$private_key" "$short_id" << 'PY_EOF'
import sys
import os
import yaml

config_path, nodes_db, node_name, port_str, db_record, uuid, server_name, priv, short_id = sys.argv[1:10]
port = int(port_str)

# 1. 更新总账本
existing_records = []
if os.path.exists(nodes_db):
    with open(nodes_db, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("TYPE=vless-reality|"):
                existing_records.append(line)
existing_records.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f:
    f.write("\n".join(existing_records) + "\n")

# 2. 读取现有配置并排除同名旧节点
listeners = []
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            loaded = yaml.safe_load(f)
            if loaded and isinstance(loaded, dict) and "listeners" in loaded:
                listeners = [l for l in loaded["listeners"] if l.get("name") != node_name]
    except Exception:
        pass

new_listener = {
    "name": node_name,
    "type": "vless",
    "port": port,
    "listen": "0.0.0.0",
    "users": [
        {"username": "1", "uuid": uuid, "flow": "xtls-rprx-vision"}
    ],
    "reality-config": {
        "dest": f"{server_name}:443",
        "private-key": priv,
        "short-id": [short_id],
        "server-names": [server_name]
    }
}
listeners.append(new_listener)

# 3. 独立序列化并用双换行拼接空行
blocks = []
for item in listeners:
    dumped = yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip()
    indented = "\n".join("  " + line for line in dumped.splitlines())
    blocks.append(indented)

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f:
    f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF

    systemctl restart mihomo

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${GREEN}  VLESS-REALITY 服务端入站已成功写入并重启！${NC}"
    echo -e "${GREEN}========================================================${NC}"
    echo -e "入站标识 : ${YELLOW}${node_name}${NC}"
    echo -e "监听端口 : ${YELLOW}${port}${NC}"
    echo -e "UUID     : ${YELLOW}${uuid}${NC}"
    echo -e "回落域名 : ${YELLOW}${server_name}${NC}"
    echo -e "数据留档 : ${CYAN}${NODES_DB}${NC}"
    echo -e "${GREEN}========================================================${NC}"
}

# ------------------------------------------------------------------------------
# Hysteria 2 (自签证书 + SHA-256 指纹 + ALPN h3) 服务端核心写入模块
# ------------------------------------------------------------------------------
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
    local port_mode="auto"
    local manual_port=""
    if [[ "$port_mode_choice" == "2" ]]; then
        port_mode="manual"
        read -p "请输入要指定的 UDP 端口 [20000-60000]: " manual_port
    fi

    local port
    port=$(get_available_port "$port_mode" "$manual_port")
    if [[ -z "$port" ]]; then
        echo -e "${RED}[ERROR] 端口获取失败，取消操作。${NC}"
        return 1
    fi

    local hy2_password
    hy2_password=$(openssl rand -hex 12 2>/dev/null | tr -d '\r\n')

    local cert_dir="${CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local cert_file="${cert_dir}/hy2.crt"
    local key_file="${cert_dir}/hy2.key"
    local sni_domain="gateway.icloud.com"

    echo -e "${CYAN}[INFO] 正在为 Hysteria 2 生成自签 TLS 证书...${NC}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -days 3650 -subj "/CN=${sni_domain}" 2>/dev/null

    local sha256_fingerprint
    sha256_fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$cert_file" | cut -d '=' -f 2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    if [[ -z "$sha256_fingerprint" ]]; then
        echo -e "${RED}[ERROR] 证书 SHA-256 指纹计算失败！${NC}"
        return 1
    fi

    local server_ip
    server_ip=$(curl -s4 ip.sb 2>/dev/null | tr -d '\r\n' || echo "YOUR_SERVER_IP")

    manage_firewall_port "add" "$port" "udp" "YinDun-Hy2-${port}"

    local node_name="hysteria2-in-${host_name}"
    local db_record="TYPE=hysteria2|NAME=${node_name}|PORT=${port}|PASSWORD=${hy2_password}|FINGERPRINT=${sha256_fingerprint}|SNI=${sni_domain}|IP=${server_ip}"

    # Python 安全写入：确保多协议独立区块并带有完美的空行
    python3 - "$CONFIG_FILE" "$NODES_DB" "$node_name" "$port" "$db_record" "$hy2_password" "$cert_file" "$key_file" << 'PY_EOF'
import sys
import os
import yaml

config_path, nodes_db, node_name, port_str, db_record, password, cert_file, key_file = sys.argv[1:9]
port = int(port_str)

# 1. 更新总账本
existing_records = []
if os.path.exists(nodes_db):
    with open(nodes_db, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("TYPE=hysteria2|"):
                existing_records.append(line)
existing_records.append(db_record)
with open(nodes_db, "w", encoding="utf-8") as f:
    f.write("\n".join(existing_records) + "\n")

# 2. 读取现有配置并排除同名旧节点
listeners = []
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            loaded = yaml.safe_load(f)
            if loaded and isinstance(loaded, dict) and "listeners" in loaded:
                listeners = [l for l in loaded["listeners"] if l.get("name") != node_name]
    except Exception:
        pass

new_listener = {
    "name": node_name,
    "type": "hysteria2",
    "port": port,
    "listen": "0.0.0.0",
    "users": {
        "1": password
    },
    "alpn": ["h3"],
    "certificate": cert_file,
    "private-key": key_file
}
listeners.append(new_listener)

# 3. 独立序列化并用双换行拼接空行
blocks = []
for item in listeners:
    dumped = yaml.safe_dump([item], allow_unicode=True, sort_keys=False).strip()
    indented = "\n".join("  " + line for line in dumped.splitlines())
    blocks.append(indented)

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as f:
    f.write("listeners:\n" + "\n\n".join(blocks) + "\n")
PY_EOF

    systemctl restart mihomo

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${GREEN}  Hysteria 2 服务端入站已成功追加写入并重启！${NC}"
    echo -e "${GREEN}========================================================${NC}"
    echo -e "入站标识   : ${YELLOW}${node_name}${NC}"
    echo -e "监听端口   : ${YELLOW}${port} (UDP)${NC}"
    echo -e "连接密码   : ${YELLOW}${hy2_password}${NC}"
    echo -e "伪装 SNI   : ${YELLOW}${sni_domain}${NC}"
    echo -e "SHA-256指纹: ${YELLOW}${sha256_fingerprint}${NC}"
    echo -e "数据留档   : ${CYAN}${NODES_DB}${NC}"
    echo -e "${GREEN}========================================================${NC}"
}

show_menu() {
    clear
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${GREEN}        YinDun Server Node Configuration Menu          ${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo "1. 添加 VLESS-REALITY 服务端节点"
    echo "2. 添加 Hysteria 2 服务端节点 (自签证书 + SHA-256 指纹)"
    echo "0. 退出脚本"
    echo -e "${CYAN}========================================================${NC}"
    read -p "请选择操作 [0-2]: " choice

    case "$choice" in
        1)
            add_vless_reality_server_config
            ;;
        2)
            add_hysteria2_server_config
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选择！${NC}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_menu
fi
