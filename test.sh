#!/usr/bin/env bash

# ==========================================
# 1. 粘贴前文的检测与防火墙管理函数
# ==========================================

check_and_install_dependencies() {
    if ! command -v ss &>/dev/null; then
        echo -e "\033[33m[INFO] 检测到系统缺少网络诊断工具 (ss)，正在自动安装...\033[0m"
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y iproute2 &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y iproute &>/dev/null
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
            read -p "请输入您指定的端口 [20000-60000]: " target_port
        else
            target_port="$manual_port"
        fi

        if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
            echo -e "\033[31m[ERROR] 端口输入无效！\033[0m"
            return 1
        fi

        if check_port_used "$target_port"; then
            echo -e "\033[33m[WARN] 端口 ${target_port} 当前已被占用！\033[0m"
            read -p "是否仍要强行使用此端口？[y/N]: " force_choice
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
        echo -e "\033[32m[INFO] 自动分配可用端口: ${target_port}\033[0m"
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
                    echo -e "\033[32m[UFW 测试] 已成功开放端口 ${port}/${p} (备注: ${comment})\033[0m"
                elif [[ "$action" == "remove" ]]; then
                    ufw delete allow "$port/$p" >/dev/null 2>&1
                    echo -e "\033[33m[UFW 测试] 已从防火墙移除端口 ${port}/${p}\033[0m"
                fi
            done
            ufw reload >/dev/null 2>&1
            ;;
        firewalld)
            for p in "${protos[@]}"; do
                if [[ "$action" == "add" ]]; then
                    firewall-cmd --permanent --add-port="${port}/${p}" >/dev/null 2>&1
                    echo -e "\033[32m[Firewalld 测试] 已成功永久开放端口 ${port}/${p}\033[0m"
                elif [[ "$action" == "remove" ]]; then
                    firewall-cmd --permanent --remove-port="${port}/${p}" >/dev/null 2>&1
                    echo -e "\033[33m[Firewalld 测试] 已从防火墙移除端口 ${port}/${p}\033[0m"
                fi
            done
            firewall-cmd --reload >/dev/null 2>&1
            ;;
        *)
            echo -e "\033[33m[WARN] 未检测到主流防火墙，跳过测试。\033[0m"
            ;;
    esac
}

# ==========================================
# 2. 执行测试用例
# ==========================================
echo "=== 开始测试端口与防火墙模块 ==="

# 测试 1: 自动获取一个空闲端口
TEST_PORT=$(get_available_port "auto")
echo "获取到的测试端口为: $TEST_PORT"

# 测试 2: 将该端口写入防火墙并带上备注
if [ -n "$TEST_PORT" ]; then
    echo "正在测试添加防火墙规则..."
    manage_firewall_port "add" "$TEST_PORT" "tcp" "YinDun-Test-Rule"
    
    # 暂停 3 秒让你可以去系统中验证
    echo "请在另一个终端使用命令检查防火墙（如 ufw status 或 firewall-cmd --list-ports）..."
    sleep 3

    # 测试 3: 清理刚刚添加的防火墙规则
    echo "正在测试清理防火墙规则..."
    manage_firewall_port "remove" "$TEST_PORT" "tcp" "YinDun-Test-Rule"
fi

echo "=== 测试结束 ==="
