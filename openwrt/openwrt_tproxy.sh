#!/bin/sh

#################################################
# 描述: OpenWrt sing-box TProxy模式 配置脚本
# 版本: 1.0.0
# 作者: Youtube: 七尺宇
# 用途: 配置和启动 sing-box TProxy模式 代理服务
#################################################

# 配置参数
BACKEND_URL="http://192.168.10.12:5000"  # 转换后端地址
SUBSCRIPTION_URL=""  # 订阅地址
TEMPLATE_URL="https://raw.githubusercontent.com/qichiyuhub/rule/refs/heads/master/config/singbox/config_tproxy.json"  # 配置文件（规则模板)
TPROXY_PORT=7895  # sing-box tproxy 端口，和配置文件（规则模板）里的端口一致！
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
MAX_RETRIES=3  # 最大重试次数
RETRY_DELAY=3  # 重试间隔时间（秒）
CONFIG_FILE="/etc/sing-box/config.json"
CONFIG_BACKUP="/etc/sing-box/config.json.backup"

# 默认日志文件路径
LOG_FILE="${LOG_FILE:-/var/log/sing-box-config.log}"

# 重定向输出到日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

# 获取当前时间
timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# 错误处理函数
error_exit() {
    echo "$(timestamp) 错误: $1" >&2
    exit "${2:-1}"
}

# 捕获中断信号以进行清理
trap 'error_exit "脚本被中断"' INT TERM

# 检查命令是否存在
check_command() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "$cmd 未安装，请安装后再运行此脚本"
    fi
}

# 停止 sing-box 服务
if killall sing-box 2>/dev/null; then
    echo "$(timestamp) 已停止现有 sing-box 服务"
else
    echo "$(timestamp) 没有运行中的 sing-box 服务"
fi
# 检查并删除已存在的 sing-box 表（如果存在）
if nft list tables | grep -q 'inet sing-box'; then
    nft delete table inet sing-box
fi

# 检查网络连接
check_network() {
    local ping_count=3
    local test_host="8.8.8.8"
    
    echo "$(timestamp) 检查网络连接..."
    if ! ping -c $ping_count $test_host >/dev/null 2>&1; then
        error_exit "网络连接失败，请检查网络设置"
    fi
}

# 检查端口占用
check_port() {
    local port=$1
    if netstat -tuln | grep -q ":$port "; then
        error_exit "端口 $port 已被占用"
    fi
}

# 下载配置文件
download_config() {
    local retry=0
    local url="$1"
    local output_file="$2"
    
    while [ $retry -lt $MAX_RETRIES ]; do
        if curl -L --connect-timeout 10 --max-time 30 -v "$url" -o "$output_file"; then
            echo "$(timestamp) 配置文件下载成功"
            return 0
        fi
        retry=$((retry + 1))
        echo "$(timestamp) 下载失败，第 $retry 次重试..."
        sleep $RETRY_DELAY
    done
    return 1
}

# 备份配置文件
backup_config() {
    local config_file="$1"
    local backup_file="$2"
    
    if [ -f "$config_file" ]; then
        cp "$config_file" "$backup_file"
        echo "$(timestamp) 已备份当前配置"
    fi
}

# 还原配置文件
restore_config() {
    local backup_file="$1"
    local config_file="$2"
    
    if [ -f "$backup_file" ]; then
        cp "$backup_file" "$config_file"
        echo "$(timestamp) 已还原至备份配置"
    fi
}



# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    error_exit "此脚本需要 root 权限运行"
fi

# 检查必要命令是否安装
check_command "sing-box"
check_command "curl"
check_command "nft"
check_command "ip"
check_command "ping"
check_command "netstat"

# 检查网络和端口
check_network
check_port "$TPROXY_PORT"


# 创建配置目录
mkdir -p /etc/sing-box

# 备份当前配置
backup_config "$CONFIG_FILE" "$CONFIG_BACKUP"

# 下载新配置
echo "$(timestamp) 开始下载配置文件..."
FULL_URL="${BACKEND_URL}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"

if ! download_config "$FULL_URL" "$CONFIG_FILE"; then
    error_exit "配置文件下载失败，已重试 $MAX_RETRIES 次"
fi

# 验证配置
if ! sing-box check -c "$CONFIG_FILE"; then
    echo "$(timestamp) 配置文件验证失败，正在还原备份"
    restore_config "$CONFIG_BACKUP" "$CONFIG_FILE"
    error_exit "配置验证失败"
fi


# 创建防火墙规则文件
echo "$(timestamp) 创建防火墙规则文件..."
cat > /etc/nftables.d/99-singbox.nft << EOF
#!/usr/sbin/nft -f

add table inet sing-box

# 创建新的链
add chain inet sing-box prerouting { type filter hook prerouting priority mangle; policy accept; }
add chain inet sing-box output { type route hook output priority mangle; policy accept; }

# 添加规则
table inet sing-box {
    chain prerouting {
        meta l4proto { tcp, udp } th dport 53 tproxy to :$TPROXY_PORT accept comment "DNS透明代理"
        fib daddr type local meta l4proto { tcp, udp } th dport $TPROXY_PORT reject
        fib daddr type local accept
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } accept
        meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set $PROXY_FWMARK accept
    }

    chain output {
        meta mark $PROXY_FWMARK accept
        meta l4proto { tcp, udp } th dport 53 meta mark set $PROXY_FWMARK accept
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } accept
        meta l4proto { tcp, udp } meta mark set $PROXY_FWMARK accept
    }
}
EOF

# 设置权限
chmod 644 /etc/nftables.d/99-singbox.nft

# 应用防火墙规则
if ! nft -f /etc/nftables.d/99-singbox.nft; then
    error_exit "应用防火墙规则失败"
fi

# 配置路由规则
ip rule del table $PROXY_ROUTE_TABLE >/dev/null 2>&1  # 删除已存在的规则
ip rule add fwmark $PROXY_FWMARK table $PROXY_ROUTE_TABLE

# 清理并添加路由
ip route flush table $PROXY_ROUTE_TABLE >/dev/null 2>&1
ip route add local default dev lo table $PROXY_ROUTE_TABLE

# 清理缓存
if [ -f "/etc/sing-box/cache.db" ]; then
    rm -f /etc/sing-box/cache.db
fi

# 启动服务并将输出重定向到 /dev/null
echo "$(timestamp) 启动 sing-box 服务..."
sing-box run -c "$CONFIG_FILE" >/dev/null 2>&1 &

# 检查服务状态
sleep 2
if pgrep -x "sing-box" > /dev/null; then
    echo "$(timestamp) sing-box 启动成功  运行模式--TProxy"
else
    error_exit "sing-box 启动失败，请检查日志"
fi