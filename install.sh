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

# 1. 智能识别 CPU 架构及 x86_64 指令集等级 (v1 ~ v4)
arch=$(uname -m)
case "$arch" in
    x86_64)
        MIHOMO_ARCH="amd64"
        VARIANT="v1"
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
        VARIANT="" 
        ;;
    armv7l)  
        MIHOMO_ARCH="armv7"
        VARIANT="" 
        ;;
    *) 
        echo -e "${RED}[ERROR] 不支持的 CPU 架构: $arch${NC}"
        exit 1 
        ;;
esac

echo -e "${CYAN}[2/5] 正在通过 GitHub 获取最新版本信息...${NC}"
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
LATEST_TAG=$(curl -sSL "$API_URL" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo -e "${RED}[ERROR] 获取最新版本号失败！${NC}"
    exit 1
fi
echo -e "远程最新版本: ${GREEN}${LATEST_TAG}${NC}"

# 动态拼接官方 .gz 直链
if [ -n "$VARIANT" ] && [ "$VARIANT" != "v1" ]; then
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/mihomo-linux-${MIHOMO_ARCH}-${VARIANT}-${LATEST_TAG}.gz"
else
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_TAG}.gz"
fi

# 兜底降级
if ! curl --output /dev/null --silent --head --fail "$DOWNLOAD_URL"; then
    echo -e "${YELLOW}[WARN] 优化版下载链接不存在，自动切换为标准版...${NC}"
    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_TAG}/mihomo-linux-${MIHOMO_ARCH}-${LATEST_TAG}.gz"
fi

# 版本比对与升级逻辑
if [ -f "${MIHOMO_DIR}/mihomo" ]; then
    LOCAL_VER=$("${MIHOMO_DIR}/mihomo" -v 2>/dev/null | awk '{print $2}')
    echo -e "当前本地版本: ${YELLOW}${LOCAL_VER}${NC}"
    
    if [[ "$LOCAL_VER" == "$LATEST_TAG" ]]; then
        read -p "当前已是最新版，是否强制重新覆盖安装？[y/N]: " choice
        [[ "$choice" != "y" && "$choice" != "Y" ]] && echo "已取消安装。" && exit 0
    else
        echo -e "${GREEN}检测到新版本，开始执行平滑升级...${NC}"
    fi
else
    echo -e "${GREEN}本地未安装 Mihomo，开始全新安装...${NC}"
fi

# 3. 下载与解压
echo -e "${CYAN}[3/5] 正在下载核心压缩包...${NC}"
rm -f "${MIHOMO_DIR}/mihomo.gz" "${MIHOMO_DIR}/mihomo"
curl -L -o "${MIHOMO_DIR}/mihomo.gz" "$DOWNLOAD_URL"

if [ ! -s "${MIHOMO_DIR}/mihomo.gz" ]; then
    echo -e "${RED}[ERROR] 下载文件失败或为空！${NC}"
    exit 1
fi

echo -e "${CYAN}正在解压核心文件...${NC}"
gunzip -f "${MIHOMO_DIR}/mihomo.gz"
mv "${MIHOMO_DIR}/mihomo"* "${MIHOMO_DIR}/mihomo" 2>/dev/null || true
chmod +x "${MIHOMO_DIR}/mihomo"

# 4. 配置 Systemd 服务（实现开机自启、崩溃自动重启）
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
    echo -e "${GREEN}  指令集优化: ${VARIANT:-standard}${NC}"
    echo -e "${GREEN}  安装路径 : ${MIHOMO_DIR}/mihomo${NC}"
    echo -e "${GREEN}  服务状态 : 运行中 (Systemd 守护 & 开机自启已就绪)${NC}"
    echo -e "${GREEN}========================================================${NC}"
else
    echo -e "\n${RED}[ERROR] Mihomo 启动失败！请检查系统日志：journalctl -u mihomo -e${NC}"
    exit 1
fi
