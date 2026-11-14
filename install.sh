#!/usr/bin/env bash
# ==============================================================================
# Project: YinDun Server Manager (install.sh)
# Description: 安装常用工具、解压套件，智能探测 CPU 指令集并自动安装/升级 Mihomo
# ==============================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

BASE_DIR="/etc/yindun"
MIHOMO_DIR="${BASE_DIR}/mihomo"
mkdir -p "${MIHOMO_DIR}"

echo -e "${CYAN}[1/5] 正在检查并安装系统常用工具及解压套件 (zip/unzip/rar)...${NC}"
if command -v apt-get &>/dev/null; then
    apt-get update -y && apt-get install -y curl wget tar unzip unrar-free 2>/dev/null || apt-get install -y curl wget tar unzip rar 2>/dev/null
elif command -v yum &>/dev/null; then
    yum install -y epel-release -y
    yum install -y curl wget tar unzip unrar rar 2>/dev/null || true
fi

# 1. 智能识别 CPU 架构及 x86_64 指令集等级 (v1 ~ v4) 避免非法指令崩溃
arch=$(uname -m)
case "$arch" in
    x86_64)
        MIHOMO_ARCH="amd64"
        VARIANT="compatible"
        
        # 探测 CPU 是否支持 AVX2 (v3) 或 AVX-512 (v4) 以榨干性能
        if grep -q "avx2" /proc/cpuinfo 2>/dev/null; then
            if grep -q "avx512f" /proc/cpuinfo 2>/dev/null; then
                VARIANT="v4"
            else
                VARIANT="v3"
            fi
        elif grep -q "sse4_2" /proc/cpuinfo 2>/dev/null; then
            VARIANT="v2"
        fi
        echo -e "${CYAN}检测到 x86_64 CPU，已自动匹配最优指令集版本: ${YELLOW}${VARIANT}${NC}"
        ;;
    aarch64) 
        MIHOMO_ARCH="arm64"
        VARIANT="compatible"
        ;;
    armv7l)  
        MIHOMO_ARCH="armv7"
        VARIANT="compatible"
        ;;
    *) 
        echo -e "${RED}[ERROR] 不支持的 CPU 架构: $arch${NC}"
        exit 1 
        ;;
esac

echo -e "${CYAN}[2/5] 正在准备下载 Mihomo 核心 (架构: ${MIHOMO_ARCH}, 优化级: ${VARIANT})...${NC}"

# 使用官方静态重定向直链，确保 100% 能够下载成功
DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${MIHOMO_ARCH}-${VARIANT}.tar.gz"

# 如果指定变体下载失败，自动回退到 compatible 兼容版
if ! curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL"; then
    echo -e "${YELLOW}[WARN] 优化版下载链接不可用，自动切换为 compatible 兼容版...${NC}"
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${MIHOMO_ARCH}-compatible.tar.gz"
fi

# 获取远程版本 Tag 用于比对
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
LATEST_TAG=$(curl -sSL "$API_URL" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$LATEST_TAG" ] && LATEST_TAG="latest"

# 2. 版本比对与交互逻辑
if [ -f "${MIHOMO_DIR}/mihomo" ]; then
    LOCAL_VER=$("${MIHOMO_DIR}/mihomo" -v 2>/dev/null | awk '{print $2}')
    echo -e "当前本地已安装版本: ${YELLOW}${LOCAL_VER}${NC}"
    echo -e "远程获取最新版本: ${CYAN}${LATEST_TAG}${NC}"
    
    if [[ "$LOCAL_VER" == "$LATEST_TAG" ]]; then
        read -p "当前已是最新版，是否需要覆盖重新安装？[y/N]: " choice
        [[ "$choice" != "y" && "$choice" != "Y" ]] && echo "已取消安装。" && exit 0
    else
        echo -e "${GREEN}检测到新版本，准备开始升级...${NC}"
    fi
else
    echo -e "${GREEN}本地未检测到 Mihomo，开始全新安装...${NC}"
fi

# 3. 下载与解压
echo -e "${CYAN}[3/5] 正在下载核心压缩包...${NC}"
rm -f "${MIHOMO_DIR}/mihomo.tar.gz"
curl -L -o "${MIHOMO_DIR}/mihomo.tar.gz" "$DOWNLOAD_URL"

# 检查文件大小是否异常（小于 1MB 说明下载失败或超时）
if [ ! -s "${MIHOMO_DIR}/mihomo.tar.gz" ] || [ $(stat -c%s "${MIHOMO_DIR}/mihomo.tar.gz" 2>/dev/null || stat -f%z "${MIHOMO_DIR}/mihomo.tar.gz" 2>/dev/null) -lt 1048576 ]; then
    echo -e "${RED}[ERROR] 下载文件大小异常或连接超时，请检查网络！${NC}"
    exit 1
fi

echo -e "${CYAN}正在解压核心文件...${NC}"
tar -xzf "${MIHOMO_DIR}/mihomo.tar.gz" -C "${MIHOMO_DIR}"

# 动态寻找解压出来的二进制文件并重命名
UNZIPPED_BIN=$(find "${MIHOMO_DIR}" -maxdepth 1 -type f -name "mihomo-linux-*" | head -n 1)
if [ -n "$UNZIPPED_BIN" ]; then
    mv "$UNZIPPED_BIN" "${MIHOMO_DIR}/mihomo"
fi

chmod +x "${MIHOMO_DIR}/mihomo"
rm -f "${MIHOMO_DIR}/mihomo.tar.gz"

# 4. 配置 Systemd 服务（实现开机自启与异常重启）
echo -e "${CYAN}[4/5] 正在配置 Systemd 服务守护进程（支持开机自启与崩溃重启）...${NC}"
cat <<EOF > /etc/systemd/system/mihomo.service
[Unit]
Description=YinDun Mihomo Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${MIHOMO_DIR}
ExecStart=${MIHOMO_DIR}/mihomo -d ${MIHOMO_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mihomo
systemctl restart mihomo

# 5. 运行状态检测
echo -e "${CYAN}[5/5] 正在检测 Mihomo 运行状态...${NC}"
sleep 2
if systemctl is-active --quiet mihomo; then
    RUN_VER=$("${MIHOMO_DIR}/mihomo" -v 2>/dev/null | awk '{print $2}')
    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${GREEN}  恭喜！Mihomo 核心安装并成功运行！${NC}"
    echo -e "${GREEN}  当前版本 : ${RUN_VER}${NC}"
    echo -e "${GREEN}  指令集优化: ${VARIANT}${NC}"
    echo -e "${GREEN}  安装路径 : ${MIHOMO_DIR}/mihomo${NC}"
    echo -e "${GREEN}  服务状态 : 运行中 (Systemd 守护 & 开机自启已就绪)${NC}"
    echo -e "${GREEN}========================================================${NC}"
else
    echo -e "\n${RED}[ERROR] Mihomo 启动失败！请检查日志：journalctl -u mihomo -e${NC}"
    exit 1
fi
