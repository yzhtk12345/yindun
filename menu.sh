#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Mihomo Server Manager (menu.sh)
# Description: 主菜单与系统环境探测面板
# ==============================================================================

# 统一根目录定义
BASE_DIR="/etc/yindun"
MIHOMO_DIR="${BASE_DIR}/mihomo"
WARP_DIR="${BASE_DIR}/warp"

# 脚本版本号
SCRIPT_VERSION="v1.0.0"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
NC="\033[0m"

# 远程仓库 Base URL (后续改成你的 GitHub Raw 链接)
REPO_URL="https://raw.githubusercontent.com/yzhtk12345/yindun/refs/heads/main"

# 远程调用子脚本函数
run_remote_script() {
    local script_name="$1"
    echo -e "\n${CYAN}正在加载并执行 ${script_name} ...${NC}\n"
    bash <(curl -sSL "${REPO_URL}/${script_name}")
}

# ------------------------------------------------------------------------------
# 系统与环境信息探测函数
# ------------------------------------------------------------------------------
get_system_info() {
    # 1. 操作系统信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_INFO="${PRETTY_NAME:-$ID}"
    else
        OS_INFO="Unknown Linux"
    fi

    # 2. 内核版本
    KERNEL_VERSION=$(uname -r)

    # 3. IP 栈检测 (检查 IPv4 和 IPv6 连通性与地址)
    IPV4_STATUS="${RED}未检测到${NC}"
    IPV6_STATUS="${RED}未检测到${NC}"
    
    local ip4
    ip4=$(curl -4 -s --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    if [ -n "$ip4" ]; then
        IPV4_STATUS="${GREEN}已连接 (${ip4})${NC}"
    fi

    local ip6
    ip6=$(curl -6 -s --connect-timeout 3 https://api6.ipify.org 2>/dev/null)
    if [ -n "$ip6" ]; then
        IPV6_STATUS="${GREEN}已连接 (${ip6})${NC}"
    fi

    # 判断单 IP 还是双 IP
    if [[ -n "$ip4" && -n "$ip6" ]]; then
        IP_TYPE="${GREEN}双栈 (IPv4 + IPv6)${NC}"
    elif [[ -n "$ip4" ]]; then
        IP_TYPE="${YELLOW}单栈 (仅 IPv4)${NC}"
    elif [[ -n "$ip6" ]]; then
        IP_TYPE="${YELLOW}单栈 (仅 IPv6)${NC}"
    else
        IP_TYPE="${RED}无公网 IP${NC}"
    fi

    # 4. Mihomo 安装状态与版本检查
    if [ -f "${MIHOMO_DIR}/mihomo" ]; then
        MIHOMO_STATUS="${GREEN}已安装${NC}"
        # 获取本地 mihomo 版本
        MIHOMO_VER=$("${MIHOMO_DIR}/mihomo" -v 2>/dev/null | awk '{print $2}' || echo "未知版本")
    else
        MIHOMO_STATUS="${RED}未安装${NC}"
        MIHOMO_VER="N/A"
    fi

    # 5. WARP 状态检查 (预留)
    if [ -d "$WARPS_DIR" ] && systemctl is-active --quiet wg-quick@wgcf 2>/dev/null; then
        WARP_STATUS="${GREEN}运行中${NC}"
    else
        WARP_STATUS="${YELLOW}未启用${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 显示主菜单面板
# ------------------------------------------------------------------------------
show_menu() {
    clear
    # 每次显示菜单前刷新一次状态
    get_system_info

    echo -e "${BLUE}========================================================${NC}"
    echo -e "${CYAN}        YinDun Mihomo Server Control Panel               ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    echo -e " 脚本版本 : ${YELLOW}${SCRIPT_VERSION}${NC}   | 安装路径 : ${CYAN}${BASE_DIR}${NC}"
    echo -e " 系统发行 : ${OS_INFO}"
    echo -e " 系统内核 : ${KERNEL_VERSION}"
    echo -e " 网络状态 : ${IP_TYPE}"
    echo -e "   ├─ IPv4  : ${IPV4_STATUS}"
    echo -e "   └─ IPv6  : ${IPV6_STATUS}"
    echo -e " 服务状态 : Mihomo [${MIHOMO_STATUS} - ${MIHOMO_VER}] | WARP [${WARP_STATUS}]"
    echo -e "${BLUE}--------------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} 安装/更新 Mihomo 核心 (install.sh)"
    echo -e " ${GREEN}2.${NC} 生成/修改配置文件 (config.sh)"
    echo -e " ${GREEN}3.${NC} 生成客户端订阅信息 (sub.sh)"
    echo -e " ${GREEN}4.${NC} 开启/配置 BBR 优化 (bbr.sh)"
    echo -e " ${GREEN}5.${NC} 配置 Cloudflare WARP (warp.sh)"
    echo -e " ${RED}0.${NC} 退出脚本"
    echo -e "${BLUE}========================================================${NC}"
    read -p "请输入选项 [0-5]: " choice

    case "$choice" in
        1) run_remote_script "install.sh" ;;
        2) run_remote_script "config.sh" ;;
        3) run_remote_script "sub.sh" ;;
        4) run_remote_script "bbr.sh" ;;
        5) run_remote_script "warp.sh" ;;
        0) echo -e "${GREEN}感谢使用，再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效的选项，请重新输入！${NC}" ;;
    esac

    echo ""
    read -p "按回车键返回主菜单..."
}

# 主循环
while true; do
    show_menu
done
