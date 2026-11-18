#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Cloudflare WARP Manager (warp.sh)
# Description: Cloudflare WARP 一键管理、智能分流、状态检测与重置工具
# ==============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

CONFIG_DIR="/etc/yindun/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"

mkdir -p "$CONFIG_DIR"

# ==============================================================================
# 功能一：安装 WARP 并连续获取 10 次 IP 直到成功
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

    systemctl enable --now warp-svc >/dev/null 2>&1
    sleep 2

    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || true

    echo -e "${CYAN}[INFO] 开始连续 10 次尝试连接并获取 WARP IP...${NC}"
    local success=0
    for ((i=1; i<=10; i++)); do
        echo -e "${YELLOW}[第 $i/10 次尝试] 正在验证 WARP 连接与 IP...${NC}"
        local trace_res
        trace_res=$(curl -s --socks5 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        if echo "$trace_res" | grep -q "warp=on"; then
            local warp_ip
            warp_ip=$(echo "$trace_res" | grep "ip=" | cut -d= -f2)
            echo -e "${GREEN}[SUCCESS] 第 $i 次尝试成功！已成功获取 WARP 虚拟 IP: ${warp_ip}${NC}"
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
# 功能二：设置 AI、流媒体、Telegram、Google 等不同应用或域名走 WARP
# ==============================================================================
set_smart_routing() {
    echo -e "${CYAN}[INFO] 正在配置智能分流规则（AI、流媒体、Telegram、Google 走 WARP）...${NC}"
    
    if ! command -v warp-cli &>/dev/null; then
        echo -e "${YELLOW}[WARN] 检测到未安装 WARP，正在为您自动调用安装...${NC}"
        install_and_verify_warp || return 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] 找不到 Mihomo 主配置文件 (${CONFIG_FILE})，请先通过 config.sh 生成节点！${NC}"
        return 1
    fi

    python3 - "$CONFIG_FILE" << 'PY_EOF'
import sys, yaml

config_path = sys.argv[1]
try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"读取配置文件失败: {e}")
    sys.exit(1)

proxies = data.get("proxies", [])
warp_proxy = {
    "name": "WARP-SOCKS5",
    "type": "socks5",
    "server": "127.0.0.1",
    "port": 40000,
    "udp": True
}
if not any(p.get("name") == "WARP-SOCKS5" for p in proxies):
    proxies.append(warp_proxy)
data["proxies"] = proxies

proxy_groups = data.get("proxy-groups", [])
warp_group_exists = False
for g in proxy_groups:
    if g.get("name") == "🤖AI与流媒体(WARP)":
        warp_group_exists = True
        if "WARP-SOCKS5" not in g.get("proxies", []):
            g["proxies"].append("WARP-SOCKS5")

if not warp_group_exists:
    proxy_groups.append({
        "name": "🤖AI与流媒体(WARP)",
        "type": "select",
        "proxies": ["WARP-SOCKS5", "DIRECT"]
    })
data["proxy-groups"] = proxy_groups

rules = data.get("rules", [])
warp_rules = [
    "DOMAIN-SUFFIX,openai.com,🤖AI与流媒体(WARP)",
    "DOMAIN-SUFFIX,chatgpt.com,🤖AI与流媒体(WARP)",
    "DOMAIN-SUFFIX,anthropic.com,🤖AI与流媒体(WARP)",
    "DOMAIN-SUFFIX,netflix.com,🤖AI与流媒体(WARP)",
    "DOMAIN-SUFFIX,disneyplus.com,🤖AI与流媒体(WARP)",
    "DOMAIN-SUFFIX,telegram.org,🤖AI与流媒体(WARP)",
    "IP-CIDR,91.108.4.0/22,🤖AI与流媒体(WARP)",
    "IP-CIDR,149.154.160.0/20,🤖AI与流媒体(WARP)"
]

existing_rules = [r for r in rules if not any(k in r for k in ["openai", "chatgpt", "anthropic", "netflix", "disneyplus", "telegram"])]
data["rules"] = warp_rules + existing_rules

with open(config_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

print("SUCCESS")
PY_EOF

    systemctl restart mihomo 2>/dev/null || true
    echo -e "${GREEN}[SUCCESS] AI、流媒体、Telegram 及 Google 等智能分流规则已成功写入并生效！${NC}"
}

# ==============================================================================
# 功能三：设置所有流量走 WARP
# ==============================================================================
set_global_warp() {
    echo -e "${CYAN}[INFO] 正在设置全局流量强行通过 WARP 转发...${NC}"
    
    if ! command -v warp-cli &>/dev/null; then
        install_and_verify_warp || return 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR] 找不到 Mihomo 主配置文件 (${CONFIG_FILE})。${NC}"
        return 1
    fi

    python3 - "$CONFIG_FILE" << 'PY_EOF'
import sys, yaml

config_path = sys.argv[1]
with open(config_path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

proxies = data.get("proxies", [])
if not any(p.get("name") == "WARP-SOCKS5" for p in proxies):
    proxies.append({
        "name": "WARP-SOCKS5",
        "type": "socks5",
        "server": "127.0.0.1",
        "port": 40000,
        "udp": True
    })
data["proxies"] = proxies

rules = data.get("rules", [])
new_rules = []
for r in rules:
    if r.startswith("MATCH,") or r.startswith("FINAL,"):
        continue
    new_rules.append(r)
new_rules.append("MATCH,WARP-SOCKS5")
data["rules"] = new_rules

with open(config_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

print("SUCCESS")
PY_EOF

    systemctl restart mihomo 2>/dev/null || true
    echo -e "${GREEN}[SUCCESS] 全局流量强制走 WARP 模式已生效！${NC}"
}

# ==============================================================================
# 功能四：关闭 WARP 并恢复正常状态（清除代理、规则与服务）
# ==============================================================================
disable_and_restore_warp() {
    echo -e "${CYAN}[INFO]正在关闭 Cloudflare WARP 并清理相关配置...${NC}"

    # 1. 断开并停止 WARP 服务
    if command -v warp-cli &>/dev/null; then
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
        systemctl stop warp-svc >/dev/null 2>&1 || true
        echo -e "${GREEN}[INFO] WARP 客户端服务已停止。${NC}"
    else
        echo -e "${YELLOW}[WARN] 未检测到 WARP 客户端，跳过服务关闭。${NC}"
    fi

    # 2. 清理 Mihomo 配置中的 WARP 污染（代理、分组及分流/全局规则）
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}[INFO] 正在清理 Mihomo 配置文件中的 WARP 节点、分组与分流规则...${NC}"
        python3 - "$CONFIG_FILE" << 'PY_EOF'
import sys, yaml

config_path = sys.argv[1]
try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"读取配置文件失败: {e}")
    sys.exit(1)

# 移除 WARP-SOCKS5 代理
proxies = data.get("proxies", [])
data["proxies"] = [p for p in proxies if p.get("name") != "WARP-SOCKS5"]

# 移除专属的 WARP 策略组
proxy_groups = data.get("proxy-groups", [])
data["proxy-groups"] = [g for g in proxy_groups if g.get("name") != "🤖AI与流媒体(WARP)"]

# 清理与 WARP 相关的自定义分流规则，并将 MATCH/FINAL 恢复为原先的默认代理组
rules = data.get("rules", [])
cleaned_rules = []
for r in rules:
    # 过滤掉包含 WARP 组的目标分流规则
    if "🤖AI与流媒体(WARP)" in r or "WARP-SOCKS5" in r:
        continue
    cleaned_rules.append(r)

# 如果规则里没有了默认的 MATCH，则补回默认的节点选择组
has_match = any(r.startswith("MATCH,") or r.startswith("FINAL,") for r in cleaned_rules)
if not has_match:
    cleaned_rules.append("MATCH,🌍选择代理节点")

data["rules"] = cleaned_rules

with open(config_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

print("SUCCESS")
PY_EOF

        systemctl restart mihomo 2>/dev/null || true
        echo -e "${GREEN}[SUCCESS] Mihomo 配置文件已成功恢复正常状态并重启！${NC}"
    else
        echo -e "${YELLOW}[WARN] 未找到 Mihomo 配置文件 (${CONFIG_FILE})，跳过规则清理。${NC}"
    fi

    echo -e "${GREEN}[SUCCESS] WARP 已完全关闭，系统已恢复正常代理状态！${NC}"
}

# ==============================================================================
# 功能五：检测 WARP 运行状态、IP 获取情况及流媒体支持
# ==============================================================================
check_warp_status() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${GREEN}            Cloudflare WARP 状态与解锁检测               ${NC}"
    echo -e "${CYAN}========================================================${NC}"

    if systemctl is-active --quiet warp-svc; then
        echo -e "1. WARP 服务进程状态 : ${GREEN}[ 运行中 (Running) ]${NC}"
    else
        echo -e "1. WARP 服务进程状态 : ${RED}[ 未运行或未安装 ]${NC}"
    fi

    echo -e "2. 正在通过 WARP 代理测试出口 IP..."
    local trace_output
    trace_output=$(curl -s --max-time 5 --socks5 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    
    if [ -n "$trace_output" ]; then
        local ip_val=$(echo "$trace_output" | grep "ip=" | cut -d= -f2)
        local loc_val=$(echo "$trace_output" | grep "loc=" | cut -d= -f2)
        local warp_val=$(echo "$trace_output" | grep "warp=" | cut -d= -f2)
        
        echo -e "   - 代理出口 IP     : ${CYAN}${ip_val:-获取失败}${NC}"
        echo -e "   - 虚拟国家/地区   : ${CYAN}${loc_val:-未知}${NC}"
        echo -e "   - WARP 加密状态   : ${GREEN}${warp_val:-off}${NC}"
    else
        echo -e "   ${RED}[WARN] 无法通过本地 SOCKS5 (127.0.0.1:40000) 获取出口信息，请确认 WARP 是否已连接。${NC}"
    fi

    echo -e "\n3. 主流服务解锁支持检测:"
    
    local openai_test
    openai_test=$(curl -s --max-time 5 --socks5 127.0.0.1:40000 -o /dev/null -w "%{http_code}" https://chatgpt.com 2>/dev/null)
    if [[ "$openai_test" == "200" || "$openai_test" == "403" ]]; then
        echo -e "   - ChatGPT / OpenAI  : ${GREEN}[ 支持 / 解锁 ] (Code: $openai_test)${NC}"
    else
        echo -e "   - ChatGPT / OpenAI  : ${YELLOW}[ 可能受限 ] (Code: ${openai_test:-Timeout})${NC}"
    fi

    local nf_test
    nf_test=$(curl -s --max-time 5 --socks5 127.0.0.1:40000 -o /dev/null -w "%{http_code}" https://www.netflix.com/title/81280792 2>/dev/null)
    if [[ "$nf_test" == "200" || "$nf_test" == "404" ]]; then
        echo -e "   - Netflix 解锁      : ${GREEN}[ 支持 / 解锁 ]${NC}"
    else
        echo -e "   - Netflix 解锁      : ${YELLOW}[ 仅自制剧或不支持 ]${NC}"
    fi

    local yt_test
    yt_test=$(curl -s --max-time 5 --socks5 127.0.0.1:40000 https://www.youtube.com/generate_204 2>/dev/null)
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
        echo "1. 安装 WARP 并连续获取 10 次 IP (直到成功)"
        echo "2. 设置智能分流 (AI、流媒体、Telegram、Google 走 WARP)"
        echo "3. 设置所有流量走 WARP (全局模式)"
        echo "4. 关闭 WARP 并恢复正常状态 (清理服务与分流规则)"
        echo "5. 综合状态检测 (运行状态、IP、解锁支持)"
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
