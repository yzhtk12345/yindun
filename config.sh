#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Configuration Manager (config.sh)
# Description: 负责底层网络依赖、Python检查、防火墙、端口分配、REALITY 测速及服务端入站配置写入
# ==============================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
NODES_DB="${CONFIG_DIR}/reality_nodes.txt"

mkdir -p "${CONFIG_DIR}"

# ------------------------------------------------------------------------------
# 1. 基础依赖、Python环境与端口管理模块
# ------------------------------------------------------------------------------
check_and_install_dependencies() {
    if ! command -v ss &>/dev/null; then
        echo -e "${YELLOW}[INFO] 检测到系统缺少网络诊断工具 (ss)，正在自动安装...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y iproute2 &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y iproute &>/dev/null
        fi
    fi
}

check_and_install_python() {
    if ! command -v python3 &>/dev/null; then
        echo -e "${YELLOW}[INFO] 检测到系统未安装 Python 3，正在自动安装...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y python3 &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y python3 &>/dev/null
        fi
    fi
}

check_port_used() {
    local port="$1"
    check_and_install_dependencies
    if ss -tuln | grep -q ":${port} "; then
        return 0 # 已占用
    else
        return 1 # 未占用
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

# ------------------------------------------------------------------------------
# 2. 防火墙智能管理模块
# ------------------------------------------------------------------------------
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
                elif [[ "$action" == "remove" ]]; then
                    ufw delete allow "$port/$p" >/dev/null 2>&1
                    echo -e "${YELLOW}[UFW] 已移除端口 ${port}/${p}${NC}"
                fi
            done
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            for p in "${protos[@]}"; do
                if [[ "$action" == "add" ]]; then
                    firewall-cmd --permanent --add-port="${port}/${p}" >/dev/null 2>&1
                    echo -e "${GREEN}[Firewalld] 已永久开放端口 ${port}/${p}${NC}"
                elif [[ "$action" == "remove" ]]; then
                    firewall-cmd --permanent --remove-port="${port}/${p}" >/dev/null 2>&1
                    echo -e "${YELLOW}[Firewalld] 已移除端口 ${port}/${p}${NC}"
                fi
            done
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        *)
            echo -e "${YELLOW}[WARN] 未检测到主流防火墙，跳过配置。${NC}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 3. REALITY 测速优选域名模块（极简纯净版，绝不污染返回值）
# ------------------------------------------------------------------------------
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
    
    # 绝对纯净的输出
    echo -n "$best_domain"
}

# ------------------------------------------------------------------------------
# 4. VLESS-REALITY 服务端核心写入模块
# ------------------------------------------------------------------------------
add_vless_reality_server_config() {
    check_and_install_python

    # 自动清理可能存在的历史坏配置与账本（实现脚本自动化管理）
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}[INFO] 检测到旧配置文件，正在自动重置初始化...${NC}"
        rm -f "$CONFIG_FILE"
    fi
    if [ -f "$NODES_DB" ]; then
        rm -f "$NODES_DB"
    fi

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

    # 使用 Python 安全写入干净的 YAML
    python3 - "$CONFIG_FILE" "$node_name" "$port" "$uuid" "$private_key" "$short_id" "$server_name" << 'PY_SCRIPT'
import sys
import os

config_path, node_name, port, uuid, private_key, short_id, server_name = sys.argv[1:8]

snippet = f"""  - name: "{node_name}"
    type: vless
    port: {port}
    listen: 0.0.0.0
    users:
      - username: 1
        uuid: {uuid}
        flow: xtls-rprx-vision
    reality-config:
      dest: "{server_name}:443"
      private-key: "{private_key}"
      short-id:
        - "{short_id}"
      server-names:
        - "{server_name}"
"""

os.makedirs(os.path.dirname(config_path), exist_ok=True)
header = "mixed-port: 7890\nallow-lan: true\nmode: rule\nlog-level: info\nipv6: true\nlisteners:\n"

with open(config_path, "w", encoding="utf-8") as f:
    f.write(header + snippet)
PY_SCRIPT

    # 持久化账本记录
    echo "TYPE=vless-reality|NAME=${node_name}|PORT=${port}|UUID=${uuid}|PRIV=${private_key}|PUB=${public_key}|SHORTID=${short_id}|DOMAIN=${server_name}|IP=${server_ip}" >> "${NODES_DB}"

    systemctl restart mihomo

    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${GREEN}  VLESS-REALITY 服务端入站已成功写入配置并重启！${NC}"
    echo -e "${GREEN}========================================================${NC}"
    echo -e "入站标识 : ${YELLOW}${node_name}${NC}"
    echo -e "监听端口 : ${YELLOW}${port}${NC}"
    echo -e "UUID     : ${YELLOW}${uuid}${NC}"
    echo -e "回落域名 : ${YELLOW}${server_name}${NC}"
    echo -e "数据留档 : ${CYAN}${NODES_DB}${NC}"
    echo -e "${GREEN}========================================================${NC}"
}

# 交互菜单测试
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo -e "${CYAN}=== YinDun Config 管理脚本 ==="
    echo "1. 添加 VLESS-REALITY 服务端节点"
    read -p "请选择操作 [1]: " choice
    add_vless_reality_server_config
fi
