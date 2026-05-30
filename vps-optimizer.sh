#!/usr/bin/env bash
#=============================================================================
# VPS Network Optimizer v2.4
# 简洁交互 · 极端内存 · 容器自动降级 · swap 容错
# 用法：
#   curl -fsSL RAW_URL | sudo bash            # 标准菜单
#   curl -fsSL RAW_URL | sudo bash -s -- -u   # 直接激进模式
#   curl -fsSL RAW_URL | sudo bash -s -- -s   # 直接标准模式
#=============================================================================
set -e

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo ""; echo -e "${CYAN}>>> $1${NC}"; }

# 默认模式
MODE=""
# 命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--ultra) MODE="ultra"; shift ;;
        -s|--standard) MODE="standard"; shift ;;
        -h|--help)
            echo "VPS Network Optimizer v2.4"
            echo "用法: $0 [选项]"
            echo "  -u, --ultra     直接启用激进模式"
            echo "  -s, --standard  直接启用标准模式"
            echo "  -h, --help      显示帮助"
            exit 0
            ;;
        *) shift ;;
    esac
done

# root 检测
if [[ $EUID -ne 0 ]]; then
    error "请以 root 用户运行"
    exit 1
fi

#------------ 系统与环境检测 ------------
detect_environment() {
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

    # 容器检测
    CONTAINER="none"
    CAN_SWAP=1
    if [ -f /.dockerenv ]; then
        CONTAINER="Docker"
        CAN_SWAP=0
    elif grep -qE 'docker|libpod' /proc/1/cgroup 2>/dev/null; then
        CONTAINER="Docker"
        CAN_SWAP=0
    elif grep -qE 'lxc|0::/' /proc/1/cgroup 2>/dev/null && [ ! -d /sys/fs/cgroup/systemd ]; then
        CONTAINER="LXC"
        CAN_SWAP=0
    elif [ -f /proc/vz/veinfo ]; then
        CONTAINER="OpenVZ"
        CAN_SWAP=0
    fi

    # 如果/proc/swaps已经存在有效swap，允许使用（虽然罕见）
    if grep -q '^/' /proc/swaps 2>/dev/null; then
        CAN_SWAP=1
    fi

    # 可用拥塞控制
    AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "reno")
    # 是否支持 fq 队列
    FQ_SUPPORT=0
    if modprobe sch_fq 2>/dev/null; then
        FQ_SUPPORT=1
    elif [ -e /proc/sys/net/core/default_qdisc ] && [ -w /proc/sys/net/core/default_qdisc ]; then
        local tmp=$(cat /proc/sys/net/core/default_qdisc)
        if echo "fq" > /proc/sys/net/core/default_qdisc 2>/dev/null; then
            FQ_SUPPORT=1
            echo "$tmp" > /proc/sys/net/core/default_qdisc
        fi
    fi
}

print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       VPS Network Optimizer v2.4          ║${NC}"
    echo -e "${CYAN}║   简洁交互 · 极端内存 · 容器自动降级     ║${NC}"
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
    echo -e "  虚拟化/容器 : ${CONTAINER}"
    echo -e "  可用拥塞控制: ${AVAILABLE_CC}"
    if [ $FQ_SUPPORT -eq 1 ]; then
        echo -e "  fq 队列支持 : 是"
    else
        echo -e "  fq 队列支持 : 否（将使用 pfifo_fast）"
    fi
    if [ $CAN_SWAP -eq 0 ]; then
        echo -e "  swap 支持   : 否（容器环境，跳过）"
    else
        echo -e "  swap 支持   : 是"
    fi
}

#------------ 推荐模式 ------------
recommend_mode() {
    local rec="standard"
    if [[ $MEM_TOTAL_MB -ge 4096 && $CONTAINER == "none" ]]; then
        rec="ultra"
    elif [[ $MEM_TOTAL_MB -le 256 ]]; then
        rec="standard"
        warn "内存极低 (≤256MB)，仅支持保守参数，无法激进"
    fi
    if [[ $CONTAINER != "none" ]]; then
        warn "检测到容器环境，部分优化可能受限（swap、模块、qdisc 等）"
    fi
    echo ""
    echo -e "  ${YELLOW}智能推荐模式: ${rec}${NC}"
    if [ -z "$MODE" ]; then
        echo ""
        echo "请选择优化模式："
        echo "  1) 退出 (不执行任何操作)"
        echo "  2) 标准优化 (安全均衡)"
        echo "  3) 激进模式 (最大化带宽，可能 OOM)"
    fi
}

#------------ 读取用户输入 ------------
read_choice() {
    if [ -n "$MODE" ]; then
        return
    fi
    local ch
    if [ -t 0 ]; then
        read -p "输入数字 [2]: " ch
    else
        read -p "输入数字 [2]: " ch < /dev/tty
    fi
    ch=${ch:-2}
    case $ch in
        1) MODE="exit" ;;
        2) MODE="standard" ;;
        3) MODE="ultra" ;;
        *) warn "无效输入，默认标准模式"; MODE="standard" ;;
    esac
}

#------------ 虚拟内存（带容错） ------------
SWAP_FILE="/swapfile"
setup_swap() {
    section "虚拟内存 (swap)"
    if [ $CAN_SWAP -eq 0 ]; then
        warn "当前环境不支持 swap，跳过"
        return
    fi

    local current_swap=$(free -m | awk '/Swap:/ {print $2}')
    local swap_size
    # 根据内存设定 swap 大小
    if   [[ $MEM_TOTAL_MB -le 128 ]]; then swap_size=256
    elif [[ $MEM_TOTAL_MB -le 256 ]]; then swap_size=512
    elif [[ $MEM_TOTAL_MB -le 512 ]]; then swap_size=1024
    elif [[ $MEM_TOTAL_MB -le 1024 ]]; then swap_size=2048
    elif [[ $MEM_TOTAL_MB -le 2048 ]]; then swap_size=4096
    elif [[ $MEM_TOTAL_MB -le 4096 ]]; then swap_size=6144
    else swap_size=8192
    fi
    [[ "$MODE" == "ultra" ]] && swap_size=$(( swap_size + 1024 ))

    if [[ $current_swap -ge $swap_size ]]; then
        info "当前 swap 充足 (${current_swap}MB >= ${swap_size}MB)，无需创建"
        return
    fi
    if [[ $DISK_FREE_GB -lt $(( (swap_size + 1023) / 1024 )) ]]; then
        swap_size=$(( DISK_FREE_GB * 1024 - 512 ))
        [[ $swap_size -le 128 ]] && { warn "磁盘空间太小，跳过 swap"; return; }
    fi

    info "尝试创建 ${swap_size}MB swap 文件 ..."
    # 清理旧文件
    if [ -f "$SWAP_FILE" ]; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
        rm -f "$SWAP_FILE"
    fi

    # 创建文件（fallocate 不可用则用 dd）
    if ! fallocate -l ${swap_size}M "$SWAP_FILE" 2>/dev/null; then
        warn "fallocate 失败，使用 dd 创建（可能较慢）"
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$swap_size status=none || {
            error "swap 文件创建失败，跳过"
            rm -f "$SWAP_FILE"
            return
        }
    fi

    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" > /dev/null || { error "mkswap 失败，跳过"; rm -f "$SWAP_FILE"; return; }

    # 尝试启用 swap，失败则清理
    if swapon "$SWAP_FILE" 2>/dev/null; then
        info "swap 创建成功，当前总量: $(free -m | awk '/Swap:/ {print $2}')MB"
        grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    else
        warn "swapon 失败（环境可能不支持），清理并跳过 swap"
        rm -f "$SWAP_FILE"
    fi
}

#------------ 模块加载与算法选择 ------------
load_modules() {
    section "内核模块与算法选择"
    # 队列
    if [ $FQ_SUPPORT -eq 1 ]; then
        QDISC="fq"
        info "将使用 fq 队列"
        echo "sch_fq" > /etc/modules-load.d/optimizer-fq.conf 2>/dev/null || true
    else
        QDISC="pfifo_fast"
        warn "fq 不可用，使用 pfifo_fast（无队列管理）"
    fi

    # 拥塞控制
    if echo "$AVAILABLE_CC" | grep -qw bbr; then
        CC_ALGO="bbr"
        modprobe tcp_bbr 2>/dev/null || true
    elif echo "$AVAILABLE_CC" | grep -qw bbrplus; then
        CC_ALGO="bbrplus"
        modprobe tcp_bbrplus 2>/dev/null || true
    else
        CC_ALGO=$(echo "$AVAILABLE_CC" | awk '{print $1}')
        warn "BBR 不可用，使用 ${CC_ALGO}"
    fi
    echo "tcp_${CC_ALGO}" > /etc/modules-load.d/optimizer-cc.conf 2>/dev/null || true
    info "拥塞控制: ${CC_ALGO}"
}

#------------ 生成 sysctl 配置 ------------
generate_sysctl() {
    section "生成 /etc/sysctl.conf"
    local mem=$MEM_TOTAL_MB
    local rmem_max wmem_max tcp_rmem tcp_wmem tcp_mem
    local file_max somaxconn backlog syn_backlog tw_buckets max_orphans limit_output notsent_lowat
    local syn_retries_val tcp_retries2_val early_retrans_val

    # 极端内存分档
    if [ $mem -le 128 ]; then
        rmem_max=2097152; wmem_max=2097152
        tcp_rmem="4096 32768 2097152"; tcp_wmem="4096 16384 2097152"
        tcp_mem="4096 8192 16384"
        file_max=32768; somaxconn=2048; backlog=1024; syn_backlog=1024
        tw_buckets=1024; max_orphans=4096; limit_output=65536; notsent_lowat=4096
        syn_retries_val=3; tcp_retries2_val=8; early_retrans_val=1
    elif [ $mem -le 256 ]; then
        rmem_max=4194304; wmem_max=4194304
        tcp_rmem="4096 65536 4194304"; tcp_wmem="4096 32768 4194304"
        tcp_mem="8192 16384 32768"
        file_max=32768; somaxconn=4096; backlog=2048; syn_backlog=2048
        tw_buckets=2048; max_orphans=8192; limit_output=131072; notsent_lowat=8192
        syn_retries_val=3; tcp_retries2_val=8; early_retrans_val=1
    elif [ $mem -le 512 ]; then
        rmem_max=8388608; wmem_max=8388608
        tcp_rmem="4096 131072 8388608"; tcp_wmem="4096 65536 8388608"
        tcp_mem="16384 32768 65536"
        file_max=65536; somaxconn=8192; backlog=4096; syn_backlog=4096
        tw_buckets=4096; max_orphans=16384; limit_output=262144; notsent_lowat=16384
        syn_retries_val=2; tcp_retries2_val=6; early_retrans_val=1
    elif [[ $mem -le 1024 ]]; then
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

    # 激进模式上调参数
    if [[ "$MODE" == "ultra" ]]; then
        if [ $mem -ge 1024 ]; then
            rmem_max=$(( rmem_max * 2 ))
            wmem_max=$(( wmem_max * 2 ))
            tcp_rmem="4096 $(( $(echo $tcp_rmem | awk '{print $2}') * 2 )) $rmem_max"
            tcp_wmem="4096 $(( $(echo $tcp_wmem | awk '{print $2}') * 2 )) $wmem_max"
            tcp_mem="$(( $(echo $tcp_mem | awk '{print $1}') * 2 )) $(( $(echo $tcp_mem | awk '{print $2}') * 2 )) $(( $(echo $tcp_mem | awk '{print $3}') * 2 ))"
            syn_retries_val=1; tcp_retries2_val=3; early_retrans_val=3
            limit_output=0
        elif [ $mem -ge 512 ]; then
            rmem_max=16777216; wmem_max=16777216
            tcp_rmem="4096 262144 16777216"; tcp_wmem="4096 131072 16777216"
            tcp_mem="32768 131072 262144"
            syn_retries_val=1; tcp_retries2_val=4; early_retrans_val=2
        fi
    fi

    # 备份
    local bak="/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/sysctl.conf "$bak" 2>/dev/null || true
    info "备份配置: $bak"

    cat > /etc/sysctl.conf << EOF
# Generated by VPS Optimizer v2.4
# Mode: ${MODE} | Arch: ${ARCH_TYPE} | Cores: ${CPU_CORES} | Mem: ${MEM_TOTAL_MB}MB
# Container: ${CONTAINER} | Qdisc: ${QDISC}
# Backup: $bak

fs.file-max = ${file_max}

net.core.default_qdisc = ${QDISC}
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
    info "新配置写入完成"
}

#------------ 应用配置 ------------
apply_config() {
    section "应用 sysctl 配置"
    sysctl -p /etc/sysctl.conf > /dev/null 2>&1 || warn "部分参数因内核限制未生效（可忽略）"
    info "sysctl 参数已加载"

    # 网卡队列调整
    if [ $FQ_SUPPORT -eq 1 ]; then
        if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
            info "网卡 $IFACE 队列 -> fq"
        else
            warn "网卡 fq 设置失败，已使用默认队列"
        fi
    else
        warn "fq 不支持，网卡队列未修改"
    fi
    ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null || true
}

#------------ 最终总结 ------------
final_summary() {
    section "优化完成"
    echo -e "  ${CYAN}拥塞控制  ${NC}: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "  ${CYAN}默认 Qdisc${NC}: $(sysctl -n net.core.default_qdisc)"
    echo -e "  ${CYAN}ECN       ${NC}: $(sysctl -n net.ipv4.tcp_ecn)"
    echo -e "  ${CYAN}Swap 总量 ${NC}: $(free -m | awk '/Swap:/ {print $2}') MB"
    echo ""
    info "建议重启代理/转发服务："
    echo -e "  ${YELLOW}systemctl restart v2ray${NC}"
    echo ""
    info "回滚命令："
    echo -e "  cp /etc/sysctl.conf.bak.* /etc/sysctl.conf && sysctl -p"
    echo ""
}

#-----------------------------------------------------------------------------
main() {
    print_header
    detect_environment
    print_system_info
    recommend_mode

    # 如果命令行未指定模式，交互询问；否则直接使用
    if [ -z "$MODE" ]; then
        read_choice
    fi

    if [ "$MODE" == "exit" ]; then
        info "已退出，未修改任何配置。"
        exit 0
    fi

    echo ""
    echo -e "  ${YELLOW}即将以 [${MODE}] 模式执行优化...${NC}"
    sleep 1

    setup_swap
    load_modules
    generate_sysctl
    apply_config
    final_summary
}

main "$@"
