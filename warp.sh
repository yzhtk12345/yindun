#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Cloudflare WARP Manager (warp.sh)
# Description: Cloudflare WARP 一键管理、端口自定义/随机检测与精准清理工具
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
WARP_PORT_FILE="${CONFIG_DIR}/warp_port.txt"

mkdir -p "$CONFIG_DIR"

# 检查端口占用工具
check_port_used() {
    local port="$1"
    if command -v ss &>/dev/null && ss -tuln | grep -q ":${port} "; then
        return 0
    elif command -v nc &>/dev/null && nc -z 127.0.0.1 "$port" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 获取或指定 WARP 代理端口 (20000-60000 随机或手动)
get_warp_port() {
    local target_port=""
    echo -e "${CYAN}--------------------------------------------------------${NC}" >&2
    read -p "请选择 WARP 代理端口获取方式 [1. 自动随机获取 2. 手动指定] (默认 1): " port_choice >&2
    
    if [[ "$port_choice" == "2" ]]; then
        read -p "请输入您指定的端口 [20000-60000]: " target_port >&2
        if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 20000 ] || [ "$target_port" -gt 60000 ]; then
            echo -e "${RED}[ERROR] 端口输入无效（必须在 20000-60000 之间），已自动为您随机获取！${NC}" >&2
            target_port=""
        elif check_port_used "$target_port"; then
            echo -e "${YELLOW}[WARN] 端口 ${target_port} 当前已被占用！${NC}" >&2
            read -p "是否仍要强行使用此端口？[y/N]: " force_choice >&2
            if [[ "$force_choice" != "y" && "$force_choice" != "Y" ]]; then
                target_port=""
            fi
        fi
    fi

    if [[ -z "$target_port" ]]; then
        while true; do
            target_port=$((RANDOM % 40001 + 20000))
            if ! check_port_used "$target_port"; then
                break
            fi
        done
        echo -e "${GREEN}[INFO] 已自动随机分配可用端口: ${target_port}${NC}" >&2
    else
        echo -e "${GREEN}[INFO] 将使用指定端口: ${target_port}${NC}" >&2
    fi

    echo "$target_port" > "$WARP_PORT_FILE"
    echo "$target_port"
}

# 获取当前生效的端口（默认 40000 或自定义端口）
get_current_port() {
    if [ -f "$WARP_PORT_FILE" ]; then
        cat "$WARP_PORT_FILE"
    else
        echo "40000"
    fi
}

# ==============================================================================
# 功能一：安装 WARP 并验证连接
# ==============================================================================
install_and_verify_warp() {
    echo -e "${CYAN}[INFO] 正在检查并安装 Cloudflare WARP 客户端...${NC}"
    
    if ! command -v warp-cli &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y gpg lsb-release curl >/dev/null 2>&1
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
            apt-get update -y && apt-get install -y cloudflare-warp >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-latest.rpm 2>/dev/null || true
            yum install -y cloudflare-warp >/dev/null 2>&1
        fi
    fi

    if ! command -v warp-cli &>/dev/null; then
        echo -e "${RED}[ERROR] Cloudflare WARP 客户端安装失败，请检查系统网络或包管理器。${NC}"
        return 1
    fi

    local warp_port
    if [ -f "$WARP_PORT_FILE" ]; then
        warp_port=$(cat "$WARP_PORT_FILE")
    else
        warp_port=$(get_warp_port)
    fi

    systemctl enable --now warp-svc >/dev/null 2>&1
    sleep 2

    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
    warp-cli --accept-tos proxy port "$warp_port" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || true

    echo -e "${CYAN}[INFO] 开始连续 10 次尝试连接并获取 WARP IP (监听本地端口: ${warp_port})...${NC}"
    local success=0
    for ((i=1; i<=10; i++)); do
        echo -e "${YELLOW}[第 $i/10 次尝试] 正在验证 WARP 连接与 IP...${NC}"
        local trace_res
        trace_res=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:"$warp_port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        if echo "$trace_res" | grep -q "warp=on"; then
            local warp_ip
            warp_ip=$(echo "$trace_res" | grep "ip=" | cut -d= -f2)
            echo -e "${GREEN}[SUCCESS] 第 $i 次尝试成功！已成功获取 WARP 虚拟 IP: ${warp_ip} (本地端口: ${warp_port})${NC}"
            success=1
            break
        fi
        sleep 3
    done

    if [ "$success" -eq 0 ]; then
        echo -e "${RED}[ERROR] 连续 10 次获取 WARP IP 失败，请检查网络环境或手动执行 warp-cli connect。${NC}"
        return 1
    fi
}

# ==============================================================================
# 功能二：设置智能分流通道 (切换前自动清理旧的 WARP 节点与模式)
# ==============================================================================
set_smart_routing() {
    echo -e "${CYAN}[INFO] 正在配置 WARP 智能分流通道...${NC}"
    
    if ! command -v warp-cli &>/dev/null || ! systemctl is-active --quiet warp-svc; then
        echo -e "${YELLOW}[INFO] 检测到 WARP 客户端未安装或未运行，正在引导初始化...${NC}"
        install_and_verify_warp || return 1
    fi

    local warp_port
    warp_port=$(get_current_port)

    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}[INFO] 正在清理旧 WARP 节点并写入智能分流规则 (端口: ${warp_port})...${NC}"
        python3 - "$CONFIG_FILE" "$warp_port" << 'PY_EOF'
import sys, yaml

config_path, warp_port = sys.argv[1], int(sys.argv[2])
try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"读取配置文件失败: {e}")
    sys.exit(1)

warp_names = {"WARP-Split", "WARP-Global"}
proxies = [p for p in data.get("proxies", []) if p.get("name") not in warp_names]
proxies.insert(0, {"name": "WARP-Split", "type": "socks5", "server": "127.0.0.1", "port": warp_port})
data["proxies"] = proxies

data["proxy-groups"] = [
    {"name": "🚀 节点选择", "type": "select", "proxies": ["WARP-Split", "DIRECT"]},
    {"name": "🤖 AI分流", "type": "select", "proxies": ["WARP-Split", "DIRECT"]}
]

data["rules"] = [
    "DOMAIN-SUFFIX,openai.com,🤖 AI分流",
    "DOMAIN-SUFFIX,chatgpt.com,🤖 AI分流",
    "DOMAIN-SUFFIX,netflix.com,🚀 节点选择",
    "DOMAIN-SUFFIX,netflix.net,🚀 节点选择",
    "GEOIP,LAN,DIRECT",
    "MATCH,DIRECT"
]

with open(config_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
print("SUCCESS")
PY_EOF
        systemctl restart mihomo >/dev/null 2>&1 || true
        echo -e "${GREEN}[SUCCESS] WARP 智能分流通道配置成功并已重启 Mihomo！${NC}"
    else
        echo -e "${YELLOW}[WARN] 未找到 Mihomo 配置文件 (${CONFIG_FILE})。${NC}"
    fi
}

# ==============================================================================
# 功能三：设置全局走 WARP (切换前自动清理旧的 WARP 节点与模式)
# ==============================================================================
set_global_warp() {
    echo -e "${CYAN}[INFO] 正在激活全局 WARP 代理通道...${NC}"

    if ! command -v warp-cli &>/dev/null || ! systemctl is-active --quiet warp-svc; then
        echo -e "${YELLOW}[INFO] 检测到 WARP 客户端未安装或未运行，正在引导初始化...${NC}"
        install_and_verify_warp || return 1
    fi

    local warp_port
    warp_port=$(get_current_port)

    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}[INFO] 正在清理旧 WARP 节点并写入全局代理规则 (端口: ${warp_port})...${NC}"
        python3 - "$CONFIG_FILE" "$warp_port" << 'PY_EOF'
import sys, yaml

config_path, warp_port = sys.argv[1], int(sys.argv[2])
try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"读取配置文件失败: {e}")
    sys.exit(1)

warp_names = {"WARP-Split", "WARP-Global"}
proxies = [p for p in data.get("proxies", []) if p.get("name") not in warp_names]
proxies.insert(0, {"name": "WARP-Global", "type": "socks5", "server": "127.0.0.1", "port": warp_port})
data["proxies"] = proxies

data["proxy-groups"] = [
    {"name": "PROXY", "type": "select", "proxies": ["WARP-Global", "DIRECT"]}
]

data["rules"] = [
    "MATCH,PROXY"
]

with open(config_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)
print("SUCCESS")
PY_EOF
        systemctl restart mihomo >/dev/null 2>&1 || true
        echo -e "${GREEN}[SUCCESS] 全局走 WARP 模式已成功激活并已重启 Mihomo！${NC}"
    else
        echo -e "${YELLOW}[WARN] 未找到 Mihomo 配置文件 (${CONFIG_FILE})。${NC}"
    fi
}

# ==============================================================================
# 功能四：关闭 WARP 并深度清理残留字段 (保持不变)
# ==============================================================================
disable_and_restore_warp() {
    echo -e "${CYAN}[INFO] 正在关闭 Cloudflare WARP 服务并深度清理配置文件污染...${NC}"

    if command -v warp-cli &>/dev/null; then
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
        systemctl stop warp-svc >/dev/null 2>&1 || true
        echo -e "${GREEN}[INFO] WARP 客户端服务已成功停止。${NC}"
    else
        echo -e "${YELLOW}[WARN] 未检测到 WARP 客户端，跳过服务关闭。${NC}"
    fi

    rm -f "$WARP_PORT_FILE"

    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}[INFO] 正在移除配置中由 WARP 引入的代理节点与路由规则...${NC}"
        python3 - "$CONFIG_FILE" << 'PY_EOF'
import sys, yaml

config_path = sys.argv[1]
try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"读取配置文件失败: {e}")
    sys.exit(1)

for key in ["proxies", "proxy-groups", "rules"]:
    if key in data:
        del data[key]

with open(config_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

print("SUCCESS")
PY_EOF

        systemctl restart mihomo >/dev/null 2>&1 || true
        echo -e "${GREEN}[SUCCESS] Mihomo 配置文件已成功恢复为纯净状态并重启！${NC}"
    else
        echo -e "${YELLOW}[WARN] 未找到 Mihomo 配置文件 (${CONFIG_FILE})。${NC}"
    fi

    echo -e "${GREEN}[SUCCESS] WARP 已完全关闭，所有残留配置项已彻底清除！${NC}"
}

# ==============================================================================
# 功能五：综合状态与解锁检测 (含 VPS 直连 IP 与 WARP 出口检测)
# ==============================================================================
check_warp_status() {
    local cur_port
    cur_port=$(get_current_port)

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${GREEN}        Cloudflare WARP 状态与解锁检测                  ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    if systemctl is-active --quiet warp-svc; then
        echo -e "1. WARP 服务进程状态 : ${GREEN}[ 运行中 (Running) ]${NC}"
    else
        echo -e "1. WARP 服务进程状态 : ${RED}[ 未运行或未安装 ]${NC}"
    fi

    echo -e "2. VPS 本机直连出口 IP:"
    local vps_trace_4 vps_trace_6
    vps_trace_4=$(curl -s4 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    vps_trace_6=$(curl -s6 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)

    if [ -n "$vps_trace_4" ]; then
        local vps_ip4=$(echo "$vps_trace_4" | grep "ip=" | cut -d= -f2)
        local vps_loc4=$(echo "$vps_trace_4" | grep "loc=" | cut -d= -f2)
        echo -e "   - 本机 IPv4       : ${CYAN}${vps_ip4:-无} (${vps_loc4:-未知})${NC}"
    else
        echo -e "   - 本机 IPv4       : ${YELLOW}[ 无 / 获取失败 ]${NC}"
    fi

    if [ -n "$vps_trace_6" ]; then
        local vps_ip6=$(echo "$vps_trace_6" | grep "ip=" | cut -d= -f2)
        local vps_loc6=$(echo "$vps_trace_6" | grep "loc=" | cut -d= -f2)
        echo -e "   - 本机 IPv6       : ${CYAN}${vps_ip6:-无} (${vps_loc6:-未知})${NC}"
    else
        echo -e "   - 本机 IPv6       : ${YELLOW}[ 无 / 获取失败 ]${NC}"
    fi

    echo -e "\n3. WARP 本地 SOCKS5 端口 (${cur_port}) 出口检测:"
    local trace_res ip_val loc_val warp_val ip_label
    trace_res=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:"$cur_port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)

    if [ -n "$trace_res" ]; then
        ip_val=$(echo "$trace_res" | grep "ip=" | cut -d= -f2)
        loc_val=$(echo "$trace_res" | grep "loc=" | cut -d= -f2)
        warp_val=$(echo "$trace_res" | grep "warp=" | cut -d= -f2)
        if [[ "$ip_val" == *:* ]]; then
            ip_label="WARP IPv6"
        else
            ip_label="WARP IPv4"
        fi
        echo -e "   - ${ip_label}       : ${CYAN}${ip_val:-获取失败} (${loc_val:-未知}) [WARP: ${warp_val:-off}]${NC}"
    else
        echo -e "   - WARP 出口       : ${RED}[ 获取失败 / 超时 ]${NC}"
    fi

    echo -e "\n4. 主流服务解锁支持检测:"
    
    local openai_test
    openai_test=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:"$cur_port" -o /dev/null -w "%{http_code}" https://chatgpt.com 2>/dev/null)
    if [[ "$openai_test" == "200" || "$openai_test" == "403" ]]; then
        echo -e "   - ChatGPT / OpenAI  : ${GREEN}[ 支持 / 解锁 ] (Code: $openai_test)${NC}"
    else
        echo -e "   - ChatGPT / OpenAI  : ${YELLOW}[ 可能受限 ] (Code: ${openai_test:-Timeout})${NC}"
    fi

    local nf_test
    nf_test=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:"$cur_port" -o /dev/null -w "%{http_code}" https://www.netflix.com/title/81280792 2>/dev/null)
    if [[ "$nf_test" == "200" || "$nf_test" == "404" ]]; then
        echo -e "   - Netflix 解锁      : ${GREEN}[ 支持 / 解锁 ]${NC}"
    else
        echo -e "   - Netflix 解锁      : ${YELLOW}[ 仅自制剧或不支持 ]${NC}"
    fi

    local yt_test
    yt_test=$(curl -s --max-time 5 --socks5-hostname 127.0.0.1:"$cur_port" https://www.youtube.com/generate_204 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo -e "   - YouTube / Google  : ${GREEN}[ 支持 / 访问正常 ]${NC}"
    else
        echo -e "   - YouTube / Google  : ${RED}[ 访问失败 ]${NC}"
    fi

    echo -e "${CYAN}========================================================${NC}"
    read -p "按回车键返回主菜单..."
}

# ==============================================================================
# 主控制菜单
# ==============================================================================
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}========================================================${NC}"
        echo -e "${GREEN}        YinDun Cloudflare WARP Management Menu         ${NC}"
        echo -e "${CYAN}========================================================${NC}"
        echo "1. 安装 WARP 并配置端口、获取 10 次 IP (直到成功)"
        echo "2. 设置 AI 与流媒体分流通道 (部分域名走 WARP)"
        echo "3. 设置全局 WARP 代理通道"
        echo "4. 关闭 WARP 并恢复正常状态 (深度清理残留字段)"
        echo "5. 综合状态检测 (运行状态、本机/WARP IP、解锁支持)"
        echo "0. 返回上级 / 退出"
        echo -e "${CYAN}========================================================${NC}"
        read -p "请输入选项 [0-5]: " choice

        case "$choice" in
            1)
                install_and_verify_warp
                read -p "按回车键返回主菜单..."
                ;;
            2)
                set_smart_routing
                read -p "按回车键返回主菜单..."
                ;;
            3)
                set_global_warp
                read -p "按回车键返回主菜单..."
                ;;
            4)
                disable_and_restore_warp
                read -p "按回车键返回主菜单..."
                ;;
            5)
                check_warp_status
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR] 无效的选项，请重新输入！${NC}"
                sleep 1
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_menu
fi
