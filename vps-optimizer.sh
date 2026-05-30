#!/usr/bin/env bash
#=============================================================================
# 宽带助手
# 简洁版 · 命令行参数控制 · 智能推荐
# 用法：
#   标准优化： curl -fsSL RAW_URL | sudo bash
#   激进模式： curl -fsSL RAW_URL | sudo bash -s -- --ultra
#   本地运行： sudo bash vps-optimizer.sh [--ultra]
#=============================================================================
set -e

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo ""; echo -e "${CYAN}>>> $1${NC}"; }

# 解析命令行参数
MODE="standard"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--ultra) MODE="ultra"; shift ;;
        -h|--help)
            echo "VPS Network Optimizer v2.2"
            echo "用法: $0 [选项]"
            echo "  -u, --ultra   激进模式（最大化带宽，有 OOM 风险）"
            echo "  -h, --help    显示帮助"
            exit 0
            ;;
        *) shift ;;
    esac
done

# 需要 root
if [[ $EUID -ne 0 ]]; then
    error "请以 root 用户运行"
    exit 1
fi

#------------ 系统检测 ------------
detect_system() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)  ARCH_TYPE="x86_64" ;;
        aarch64|arm64) ARCH_TYPE="arm64"  ;;
        *)             ARCH_TYPE="other"  ;;
    esac
    KERNEL=$(uname -r)
    CPU_CORES=$(nproc)
    MEM_TOTAL_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    DISK_FREE_GB=$(df -BG / | awk 'NR==2 {print int($4)}')
    IFACE=$(ip route get 1 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$IFACE" ]] && IFACE="eth0"
    AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
}

print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║               宽带助手                    ║${NC}"
    echo -e "${CYAN}║                                          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

print_system_info() {
    section "系统检测结果"
    echo -e "  架构        : ${ARCH_TYPE}"
    echo -e "  内核        : ${KERNEL}"
    echo -e "  CPU 核心    : ${CPU_CORES}"
    echo -e "  物理内存    : ${MEM_TOTAL_MB} MB"
    echo -e "  磁盘剩余    : ${DISK_FREE_GB} GB"
    echo -e "  主网卡      : ${IFACE}"
    echo -e "  可用拥塞控制: ${AVAILABLE_CC}"
}

recommend_mode() {
    local rec="standard"
    if [[ $MEM_TOTAL_MB -ge 4096 ]]; then
        rec="ultra"
    fi
    echo ""
    echo -e "  ${YELLOW}推荐模式: ${rec}${NC}"
    echo -e "  ${YELLOW}当前模式: ${MODE}${NC}"
    if [[ "$MODE" == "ultra" && "$MEM_TOTAL_MB" -le 1024 ]]; then
        warn "当前内存 ≤1G 且选择了激进模式，存在 OOM 风险！"
    fi
}

#------------ 虚拟内存 ------------
SWAP_FILE="/swapfile"
setup_swap() {
    section "配置虚拟内存 (swap)"
    local current_swap=$(free -m | awk '/Swap:/ {print $2}')
    local swap_size
    if   [[ $MEM_TOTAL_MB -le 1024 ]]; then swap_size=2048
    elif [[ $MEM_TOTAL_MB -le 2048 ]]; then swap_size=4096
    elif [[ $MEM_TOTAL_MB -le 4096 ]]; then swap_size=6144
    else swap_size=8192
    fi
    # 激进模式额外增加 1GB
    [[ "$MODE" == "ultra" ]] && swap_size=$(( swap_size + 1024 ))

    if [[ $current_swap -ge $swap_size ]]; then
        info "当前 swap 足够 (${current_swap}MB >= ${swap_size}MB)，无需创建"
        return
    fi
    if [[ $DISK_FREE_GB -lt $(( (swap_size + 1023) / 1024 )) ]]; then
        swap_size=$(( DISK_FREE_GB * 1024 - 512 ))
        [[ $swap_size -le 128 ]] && { warn "磁盘空间太小，跳过 swap"; return; }
    fi
    info "创建 ${swap_size}MB swap 文件..."
    [[ -f "$SWAP_FILE" ]] && swapoff "$SWAP_FILE" && rm -f "$SWAP_FILE"
    fallocate -l ${swap_size}M "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$swap_size status=none
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" > /dev/null
    swapon "$SWAP_FILE"
    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    info "swap 创建完成，当前 swap 总量: $(free -m | awk '/Swap:/ {print $2}')MB"
}

#------------ 内核模块 ------------
load_modules() {
    section "加载内核模块"
    if modprobe sch_fq 2>/dev/null; then
        info "sch_fq 加载成功"
        echo "sch_fq" > /etc/modules-load.d/optimizer-fq.conf
    else
        warn "sch_fq 不可用，net.core.default_qdisc 可能无法切换为 fq"
    fi

    if echo "$AVAILABLE_CC" | grep -qw bbrplus; then
        CC_ALGO="bbrplus"
        modprobe tcp_bbrplus 2>/dev/null || { CC_ALGO="bbr"; modprobe tcp_bbr; }
    else
        CC_ALGO="bbr"
        modprobe tcp_bbr 2>/dev/null
    fi
    echo "tcp_${CC_ALGO}" > /etc/modules-load.d/optimizer-cc.conf
    info "使用拥塞控制: ${CC_ALGO}"
}

#------------ 生成 sysctl 配置 ------------
generate_sysctl() {
    section "生成 /etc/sysctl.conf"
    local mem=$MEM_TOTAL_MB
    local rmem_max wmem_max tcp_rmem tcp_wmem tcp_mem
    local file_max somaxconn backlog syn_backlog tw_buckets max_orphans limit_output notsent_lowat
    local syn_retries_val tcp_retries2_val early_retrans_val

    # 参数表
    if [[ "$MODE" == "ultra" ]]; then
        if [[ $mem -le 1024 ]]; then
            rmem_max=33554432; wmem_max=33554432
            tcp_rmem="4096 262144 33554432"; tcp_wmem="4096 131072 33554432"
            tcp_mem="65536 262144 524288"
            file_max=65536; somaxconn=65535; backlog=32768; syn_backlog=32768
            tw_buckets=16384; max_orphans=65536; limit_output=0; notsent_lowat=131072
            syn_retries_val=1; tcp_retries2_val=3; early_retrans_val=3
        elif [[ $mem -le 4096 ]]; then
            rmem_max=134217728; wmem_max=134217728
            tcp_rmem="4096 524288 134217728"; tcp_wmem="4096 262144 134217728"
            tcp_mem="262144 786432 1572864"
            file_max=1000000; somaxconn=65535; backlog=65535; syn_backlog=131072
            tw_buckets=16384; max_orphans=131072; limit_output=0; notsent_lowat=262144
            syn_retries_val=1; tcp_retries2_val=3; early_retrans_val=3
        else
            rmem_max=268435456; wmem_max=268435456
            tcp_rmem="4096 1048576 268435456"; tcp_wmem="4096 524288 268435456"
            tcp_mem="1048576 1572864 2097152"
            file_max=2000000; somaxconn=65535; backlog=262144; syn_backlog=131072
            tw_buckets=32768; max_orphans=262144; limit_output=0; notsent_lowat=262144
            syn_retries_val=1; tcp_retries2_val=2; early_retrans_val=3
        fi
    else
        if [[ $mem -le 1024 ]]; then
            rmem_max=16777216; wmem_max=16777216
            tcp_rmem="4096 131072 16777216"; tcp_wmem="4096 65536 16777216"
            tcp_mem="32768 65536 131072"
            file_max=65536; somaxconn=32768; backlog=16384; syn_backlog=16384
            tw_buckets=8192; max_orphans=32768; limit_output=262144; notsent_lowat=32768
            syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
        elif [[ $mem -le 4096 ]]; then
            rmem_max=67108864; wmem_max=67108864
            tcp_rmem="4096 262144 67108864"; tcp_wmem="4096 131072 67108864"
            tcp_mem="131072 262144 524288"
            file_max=1000000; somaxconn=65535; backlog=65535; syn_backlog=65535
            tw_buckets=16384; max_orphans=65536; limit_output=0; notsent_lowat=131072
            syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
        else
            rmem_max=134217728; wmem_max=134217728
            tcp_rmem="4096 131072 134217728"; tcp_wmem="4096 65536 134217728"
            tcp_mem="524288 786432 1048576"
            file_max=2000000; somaxconn=65535; backlog=262144; syn_backlog=131072
            tw_buckets=32768; max_orphans=131072; limit_output=0; notsent_lowat=131072
            syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
        fi
    fi

    # 备份
    local bak="/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/sysctl.conf "$bak" 2>/dev/null || true
    info "备份原有配置: $bak"

    cat > /etc/sysctl.conf << EOF
# Generated by VPS Optimizer v2.2
# Mode: ${MODE} | Arch: ${ARCH_TYPE} | Cores: ${CPU_CORES} | Mem: ${MEM_TOTAL_MB}MB
# Backup: $bak

fs.file-max = ${file_max}

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC_ALGO}
net.ipv4.tcp_ecn = 0

net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_mem = ${tcp_mem}

net.ipv4.tcp_limit_output_bytes = ${limit_output}
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1

net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_reordering = 3
net.ipv4.tcp_early_retrans = ${early_retrans_val}

net.ipv4.tcp_syn_retries = ${syn_retries_val}
net.ipv4.tcp_synack_retries = ${syn_retries_val}
net.ipv4.tcp_retries1 = ${syn_retries_val}
net.ipv4.tcp_retries2 = ${tcp_retries2_val}
net.ipv4.tcp_timestamps = 1

net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = ${max_orphans}

net.core.somaxconn = ${somaxconn}
net.core.netdev_max_backlog = ${backlog}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.ip_forward = 1
net.ipv4.tcp_moderate_rcvbuf = 1

vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    info "新的 sysctl.conf 写入完成"
}

#------------ 应用配置 ------------
apply_config() {
    section "应用配置"
    sysctl -p /etc/sysctl.conf > /dev/null 2>&1 || warn "部分内核限制未能应用（通常无影响）"
    info "sysctl 已加载"

    if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
        info "网卡 $IFACE 根队列 -> fq"
    else
        warn "网卡 $IFACE fq 设置失败（不影响核心性能）"
    fi
    ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null
    info "网卡发送队列长度调整完成"
}

#------------ 总结 ------------
final_summary() {
    section "优化已完成"
    echo -e "  ${CYAN}拥塞控制  ${NC}: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "  ${CYAN}默认 Qdisc${NC}: $(sysctl -n net.core.default_qdisc)"
    echo -e "  ${CYAN}ECN       ${NC}: $(sysctl -n net.ipv4.tcp_ecn)"
    echo -e "  ${CYAN}Swap 总量 ${NC}: $(free -m | awk '/Swap:/ {print $2}') MB"
    echo ""
    info "建议重启代理/转发服务以使新连接生效："
    echo -e "  ${YELLOW}systemctl restart v2ray${NC} （或其他服务）"
    echo ""
    info "如需回滚："
    echo -e "  cp /etc/sysctl.conf.bak.* /etc/sysctl.conf && sysctl -p"
    echo ""
}

#-----------------------------------------------------------------------------
main() {
    print_header
    detect_system
    print_system_info
    recommend_mode
    setup_swap
    load_modules
    generate_sysctl
    apply_config
    final_summary
}

main
