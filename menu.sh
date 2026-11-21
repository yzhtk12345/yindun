#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Manager (menu.sh)
# Description: 主菜单与系统环境探测面板
# ==============================================================================

# 确保脚本以 root 权限运行
[[ $EUID -ne 0 ]] && echo -e "\033[31m[ERROR] 请使用 root 权限运行此脚本！(sudo bash menu.sh)\033[33m" && exit 1

# 统一根目录与子目录定义
BASE_DIR="/etc/yindun"
MIHOMO_DIR="${BASE_DIR}/mihomo"
WARP_DIR="${BASE_DIR}/warp"
LOG_DIR="${BASE_DIR}/logs"

# 自动初始化基础目录结构
mkdir -p "${MIHOMO_DIR}" "${WARP_DIR}" "${LOG_DIR}"

# 脚本版本号
SCRIPT_VERSION="v1.0.3"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
NC="\033[0m"

# 仓库 Raw 地址
REPO_URL="https://raw.githubusercontent.com/yzhtk12345/yindun/refs/heads/main"

# ------------------------------------------------------------------------------
# 安装 / 更新全局快捷命令 `yindun`
# ------------------------------------------------------------------------------
install_shortcut() {
    local local_menu="${BASE_DIR}/menu.sh"
    local shortcut_path="/usr/local/bin/yindun"

    # 1. 保存当前脚本到本地 /etc/yindun/menu.sh
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        cp -f "${BASH_SOURCE[0]}" "${local_menu}" 2>/dev/null || true
    fi

    if [ ! -f "${local_menu}" ]; then
        curl -fsSL "${REPO_URL}/menu.sh" -o "${local_menu}" 2>/dev/null || true
    fi

    if [ -f "${local_menu}" ]; then
        chmod +x "${local_menu}"
    fi

    # 2. 清理可能存在的旧 alias，避免与 /usr/local/bin/yindun 冲突
    for rc_file in "$HOME/.bashrc" "/root/.bashrc" "/etc/profile"; do
        if [ -f "$rc_file" ]; then
            sed -i '/alias yindun=/d' "$rc_file" 2>/dev/null || true
        fi
    done

    # 3. 写入全局可执行命令 /usr/local/bin/yindun
    cat <<EOF > "${shortcut_path}"
#!/usr/bin/env bash
set -u

BASE_DIR="/etc/yindun"
LOCAL_MENU="\${BASE_DIR}/menu.sh"
REPO_URL="${REPO_URL}"

if [[ \$EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash "${shortcut_path}" "\$@"
    else
        echo -e "\033[31m[ERROR] 请使用 root 权限运行 yindun！\033[0m"
        exit 1
    fi
fi

mkdir -p "\${BASE_DIR}"

# 输入 yindun 时尝试拉取最新 menu.sh；若网络失败则保留本地版本继续启动
tmp_menu="\$(mktemp)"
if curl -fsSL --connect-timeout 3 --max-time 8 "\${REPO_URL}/menu.sh" -o "\${tmp_menu}" 2>/dev/null && grep -q "YinDun Server Manager" "\${tmp_menu}"; then
    mv -f "\${tmp_menu}" "\${LOCAL_MENU}"
    chmod +x "\${LOCAL_MENU}"
else
    rm -f "\${tmp_menu}"
fi

if [ -f "\${LOCAL_MENU}" ]; then
    exec bash "\${LOCAL_MENU}" "\$@"
else
    echo -e "\033[31m[ERROR] 未找到 \${LOCAL_MENU}，且无法从远程拉取。\033[0m"
    exit 1
fi
EOF

    chmod +x "${shortcut_path}"
}

# 防止在 `/usr/local/bin/yindun` 包装器中再次触发重复写入
if [[ "${YINDUN_SHORTCUT_INSTALLED:-0}" != "1" ]]; then
    install_shortcut
    export YINDUN_SHORTCUT_INSTALLED=1
fi

# 远程调用子脚本函数
run_remote_script() {
    local script_name="$1"
    echo -e "\n${CYAN}正在从远程加载并执行 ${script_name} ...${NC}\n"
    
    if ! bash <(curl -sSL "${REPO_URL}/${script_name}"); then
        echo -e "\n${RED}[ERROR] 执行 ${script_name} 过程中发生错误或连接失败！${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 系统与环境信息探测函数
# ------------------------------------------------------------------------------
get_system_info() {
    # 1. 操作系统与主机名信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_INFO="${PRETTY_NAME:-$ID}"
    else
        OS_INFO="Unknown Linux"
    fi
    HOSTNAME_INFO=$(hostname 2>/dev/null || echo "Unknown")

    # 2. 内核版本
    KERNEL_VERSION=$(uname -r)

    # 3. BBR 状态检测
    local bbr_congestion
    bbr_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local bbr_qdisc
    bbr_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    if [[ "$bbr_congestion" == "bbr" ]]; then
        BBR_STATUS="${GREEN}已开启 ($bbr_congestion / $bbr_qdisc)${NC}"
    else
        BBR_STATUS="${YELLOW}未开启 (当前: ${bbr_congestion:-unknown})${NC}"
    fi

    # 4. IP 栈检测 (通过双栈 API 检测公网状态)
    IPV4_STATUS="${RED}未检测到${NC}"
    IPV6_STATUS="${RED}未检测到${NC}"
    
    local ip4
    ip4=$(curl -4 -s --connect-timeout 2 https://api.ipify.org 2>/dev/null)
    if [ -n "$ip4" ]; then
        IPV4_STATUS="${GREEN}已连接 (${ip4})${NC}"
    fi

    local ip6
    ip6=$(curl -6 -s --connect-timeout 2 https://api6.ipify.org 2>/dev/null)
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

    # 5. Mihomo 安装与运行状态检查
    local mihomo_run_state=""
    if systemctl is-active --quiet mihomo 2>/dev/null; then
        mihomo_run_state=" / ${GREEN}运行中${NC}"
    elif [ -f "${MIHOMO_DIR}/mihomo" ]; then
        mihomo_run_state=" / ${YELLOW}未运行${NC}"
    fi

    if [ -f "${MIHOMO_DIR}/mihomo" ]; then
        MIHOMO_STATUS="${GREEN}已安装${NC}${mihomo_run_state}"
        MIHOMO_VER=$("${MIHOMO_DIR}/mihomo" -v 2>/dev/null | head -n 1 | awk '{print $2}' || echo "获取失败")
    else
        MIHOMO_STATUS="${RED}未安装${NC}"
        MIHOMO_VER="N/A"
    fi

    # 6. WARP 状态检查 (兼容 warp-svc / warp-cli 以及 wgcf/wg-quick@wgcf)
    local warp_port=""
    if [ -f "${MIHOMO_DIR}/warp_port.txt" ]; then
        warp_port=$(cat "${MIHOMO_DIR}/warp_port.txt")
    fi

    if systemctl is-active --quiet warp-svc 2>/dev/null; then
        if command -v warp-cli &>/dev/null && warp-cli status 2>/dev/null | grep -qi "Connected"; then
            WARP_STATUS="${GREEN}运行中${NC}${warp_port:+ (SOCKS5: ${warp_port})}"
        else
            WARP_STATUS="${GREEN}运行中${NC}${warp_port:+ (端口: ${warp_port})}"
        fi
    elif systemctl is-active --quiet wg-quick@wgcf 2>/dev/null || ip link show dev wgcf 2>/dev/null | grep -q "UP"; then
        WARP_STATUS="${GREEN}运行中 (wgcf)${NC}"
    elif command -v warp-cli &>/dev/null; then
        WARP_STATUS="${YELLOW}已安装未运行${NC}"
    else
        WARP_STATUS="${YELLOW}未启用${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 显示主菜单面板
# ------------------------------------------------------------------------------
show_menu() {
    clear
    echo -e "${CYAN}正在检测系统环境，请稍候...${NC}"
    get_system_info
    clear

    echo -e "${BLUE}========================================================${NC}"
    echo -e "${CYAN}        YinDun Mihomo Server Control Panel               ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    echo -e " 脚本版本 : ${YELLOW}${SCRIPT_VERSION}${NC}   | 根路径   : ${CYAN}${BASE_DIR}${NC}"
    echo -e " 主机名称 : ${YELLOW}${HOSTNAME_INFO}${NC}"
    echo -e " 系统发行 : ${OS_INFO}"
    echo -e " 系统内核 : ${KERNEL_VERSION}"
    echo -e " BBR 状态 : ${BBR_STATUS}"
    echo -e " 网络状态 : ${IP_TYPE}"
    echo -e "   ├─ IPv4  : ${IPV4_STATUS}"
    echo -e "   └─ IPv6  : ${IPV6_STATUS}"
    echo -e " Mihomo   : ${MIHOMO_STATUS} (${MIHOMO_VER})"
    echo -e " WARP     : ${WARP_STATUS}"
    echo -e "${BLUE}--------------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} Linux 系统安全配置 (safety.sh)"
    echo -e " ${GREEN}2.${NC} 安装/更新 Mihomo 核心 (install.sh)"
    echo -e " ${GREEN}3.${NC} 生成/修改配置文件 (config.sh)"
    echo -e " ${GREEN}4.${NC} 生成客户端订阅信息 (sub.sh)"
    echo -e " ${GREEN}5.${NC} 开启/检查 BBR 优化 (bbr.sh)"
    echo -e " ${GREEN}6.${NC} 配置 Cloudflare WARP (warp.sh)"
    echo -e " ${RED}0.${NC} 退出脚本并刷新环境"
    echo -e "${BLUE}========================================================${NC}"
    read -p "请输入选项 [0-6]: " choice

    case "$choice" in
        1) run_remote_script "safety.sh" ;;
        2) run_remote_script "install.sh" ;;
        3) run_remote_script "config.sh" ;;
        4) run_remote_script "sub.sh" ;;
        5) run_remote_script "bbr.sh" ;;
        6) run_remote_script "warp.sh" ;;
        0) 
           echo -e "${GREEN}正在刷新 Shell 环境并退出...${NC}"
           exec bash 
           ;;
        *) echo -e "${RED}无效的选项，请重新输入！${NC}" ;;
    esac

    echo ""
    read -p "按回车键返回主菜单..."
}

# 主循环
while true; do
    show_menu
done
