#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Configuration Manager (config.sh)
# Description: 负责底层网络依赖、Python检查、智能防火墙（带SSH保护与Reality备注清理）、端口分配、REALITY 测速及服务端入站配置写入
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
# 2. 智能防火墙管理模块（核心：保护SSH，精准清理带 YinDun-Reality 备注的旧端口）
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

cleanup_old_reality_firewall_rules() {
    local fw_type
    fw_type=$(detect_firewall)
    echo -e "${CYAN}[INFO] 正在清理防火墙中其他旧的 Reality 端口规则（已自动排除并保护 SSH 端口）...${NC}"

    case "$fw_type" in
        ufw)
            # UFW 原理：通过 status numbered 找到包含 YinDun-Reality 的规则编号并删除
            while true; do
                local rule_num
                # 查找带有 YinDun-Reality 备注的规则编号（取第一条）
                rule_num=$(ufw status numbered | grep "YinDun-Reality" | head -n 1 | awk -F'[][]' '{print $2}')
                if [[ -z "$rule_num" ]]; then
                    break
                fi
                echo -e "${YELLOW}[UFW] 正在删除旧 Reality 防火墙规则编号: ${rule_num}${NC}"
                yes | ufw delete "$rule_num" >/dev/null 2>&1
            done
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            # Firewalld 原理：查找所有放行的端口，若有以前残留的，可以通过富规则或记录清理
            # 简单起见，如果账本里记录了旧端口，或者直接从系统中匹配带有 YinDun-Reality 的服务/端口
            local old_ports
            old_ports=$(firewall-cmd --permanent --list-ports | grep -oE '[0-9]+/tcp' || true)
            # 如果我们用的是服务或指定端口，也可以根据 reality_nodes.txt 清理
            if [ -f "$NODES_DB" ]; then
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    local old_p
                    old_p=$(echo "$line" | grep -oP 'PORT=\K[^|]+')
                    if [[ -n "$old_p" ]]; then
                        firewall-cmd --permanent --remove-port="${old_p}/tcp" >/dev/null 2>&1
                        echo -e "${YELLOW}[Firewalld] 已移除旧 Reality 端口: ${old_p}${NC}"
                    fi
                done < "$NODES_DB"
                firewall-cmd --reload >/dev/null 2>&1
            fi
            ;;
        *)
            # 如果是纯 iptables 或未启用主流防火墙，则根据账本清理
            if [ -f "$NODES_DB" ]; then
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    local old_p
                    old_p=$(echo "$line" | grep -oP 'PORT=\K[^|]+')
                    if [[ -n "$old_p" ]]; then
                        iptables -D INPUT -p tcp --dport "$old_p" -j ACCEPT 2>/dev/null || true
                        echo -e "${YELLOW}[Iptables] 已移除旧端口: ${old_p}${NC}"
                    fi
                done < "$NODES_DB"
            fi
            ;;
    esac
}

manage_firewall_port() {
    local action="$1"
    local port="$2"
    local proto="$3"
    local comment="$4"
    local fw_type
    fw_type=$(detect_firewall)

    case "$fw_type" in
        ufw)
            if [[ "$action" == "add" ]]; then
                ufw allow "$port/$proto" comment "$comment" >/dev/null 2>&1
                echo -e "${GREEN}[UFW] 已开放新端口 ${port}/${proto} (备注: ${comment})${NC}"
            fi
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            if [[ "$action" == "add" ]]; then
                firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                echo -e "${GREEN}[Firewalld] 已永久开放新端口 ${port}/${proto}${NC}"
            fi
            ;;
        iptables)
            if [[ "$action" == "add" ]]; then
                iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
                echo -e "${GREEN}[Iptables] 已放行新端口 ${port}/${proto}${NC}"
            fi
            ;;
        *)
            echo -e "${YELLOW}[WARN] 未检测到主流防火墙，跳过配置。${NC}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 3. REALITY 测速优选域名模块
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
    
    echo -n "$best_domain"
}

# ------------------------------------------------------------------------------
# 4. VLESS-REALITY 服务端核心写入模块
# ------------------------------------------------------------------------------
add_vless_reality_server_config() {
    check_and_install_python

    # 1. 在生成新节点前，自动清理防火墙中带有 YinDun-Reality 备注的其他旧端口（绝对不碰 SSH）
    cleanup_old_reality_firewall_rules

    # 2. 清理旧配置文件与旧账本
    [ -f "$CONFIG_FILE" ] && rm -f "$CONFIG_FILE"
    [ -f "$NODES_DB" ] && rm -f "$NODES_DB"

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

    # 3. 放行当前新端口，并打上 YinDun-Reality 备注
    manage_firewall_port "add" "$port" "tcp" "YinDun-Reality-${port}"

    local node_name="vless-reality-vision-in-${host_name}"

    # 使用 Python 安全写入纯入站 YAML
    python3 - "$CONFIG_FILE" "$node_name" "$port" "$uuid" "$private_key" "$short_id" "$server_name" << 'PY_SCRIPT'
import sys
import os

config_path, node_name, port, uuid, private_key, short_id, server_name = sys.argv[1:8]

snippet = f"""listeners:
  - name: "{node_name}"
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
with open(config_path, "w", encoding="utf-8") as f:
    f.write(snippet)
PY_SCRIPT

    # 持久化账本记录
    echo "TYPE=vless-reality|NAME=${node_name}|PORT=${port}|UUID=${uuid}|PRIV=${private_key}|PUB=${public_key}|SHORTID=${short_id}|DOMAIN=${server_name}|IP=${server_ip}" >> "${NODES_DB}"

    systemctl restart mihomo

    echo -e "${GREEN}========================================================${NC}"
    echo -e "${GREEN}  VLESS-REALITY 服务端入站已成功写入配置并重启！${NC}"
    echo -e "${GREEN}========================================================${NC}"
    echo -e "入站标识 : ${YELLOW}${node_name}${NC}"
    echo -e "监听端口 : ${YELLOW}${port}${NC}"
    echo -e "UUID     : ${YELLOW}${uuid}${NC}"
    echo -e "回落域名 : ${YELLOW}${server_name}${NC}"
    echo -e "数据留档 : ${CYAN}${NODES_DB}${NC}"
    echo -e "${GREEN}========================================================${NC}"
}

# ------------------------------------------------------------------------------
# 5. 主交互菜单
# ------------------------------------------------------------------------------
show_menu() {
    clear
    echo -e "${CYAN}========================================================${NC}"
    echo -e "${CYAN}         YinDun Server Configuration Manager            ${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo "1. 添加 VLESS-REALITY 服务端节点 (自动清理旧Reality端口并保护SSH)"
    echo "2. 手动清理所有旧 Reality 端口规则"
    echo "0. 退出脚本"
    echo -e "${CYAN}========================================================${NC}"
    read -p "请选择操作 [0-2]: " choice

    case "$choice" in
        1)
            add_vless_reality_server_config
            ;;
        2)
            cleanup_old_reality_firewall_rules
            echo -e "${GREEN}[SUCCESS] 旧 Reality 端口规则清理完毕！${NC}"
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] 无效的选项！${NC}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_menu
fi
