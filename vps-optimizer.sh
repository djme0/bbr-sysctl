#!/usr/bin/env bash
#=============================================================================
# VPS Network Optimizer v2.5
# 智能探测可写参数 · 自动降级 · 容器兼容
# 用法：
#   curl -fsSL RAW_URL | sudo bash
#   curl -fsSL RAW_URL | sudo bash -s -- -u   # 激进模式
#=============================================================================
set -e

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo ""; echo -e "${CYAN}>>> $1${NC}"; }

MODE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--ultra) MODE="ultra"; shift ;;
        -s|--standard) MODE="standard"; shift ;;
        -h|--help)
            echo "VPS Network Optimizer v2.5"
            echo "  -u, --ultra     激进模式"
            echo "  -s, --standard  标准模式"
            exit 0 ;;
        *) shift ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "请以 root 运行"
    exit 1
fi

#------------ 环境检测 ------------
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

    CONTAINER="none"
    CAN_SWAP=1
    if [ -f /.dockerenv ] || grep -qE 'docker|libpod' /proc/1/cgroup 2>/dev/null; then
        CONTAINER="Docker"; CAN_SWAP=0
    elif grep -qE 'lxc|0::/' /proc/1/cgroup 2>/dev/null && [ ! -d /sys/fs/cgroup/systemd ]; then
        CONTAINER="LXC"; CAN_SWAP=0
    elif [ -f /proc/vz/veinfo ]; then
        CONTAINER="OpenVZ"; CAN_SWAP=0
    fi

    AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "reno")
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
    echo -e "${CYAN}║       VPS Network Optimizer v2.5          ║${NC}"
    echo -e "${CYAN}║   智能探测 · 容器降级 · 零报错            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
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
    [ $FQ_SUPPORT -eq 1 ] && echo -e "  fq 队列支持 : 是" || echo -e "  fq 队列支持 : 否"
    [ $CAN_SWAP -eq 1 ] && echo -e "  swap 支持   : 是" || echo -e "  swap 支持   : 否"
}

#------------ 推荐模式 ------------
recommend_mode() {
    local rec="standard"
    if [[ $MEM_TOTAL_MB -ge 4096 && $CONTAINER == "none" ]]; then
        rec="ultra"
    elif [[ $MEM_TOTAL_MB -le 256 ]]; then
        rec="standard"
    fi
    echo ""
    echo -e "  ${YELLOW}推荐模式: ${rec}${NC}"
    if [ -z "$MODE" ]; then
        echo ""
        echo "选择模式: 1)退出  2)标准  3)激进"
    fi
}

read_choice() {
    if [ -n "$MODE" ]; then return; fi
    local ch
    [ -t 0 ] && read -p "输入数字 [2]: " ch || read -p "输入数字 [2]: " ch < /dev/tty
    ch=${ch:-2}
    case $ch in
        1) MODE="exit" ;;
        2) MODE="standard" ;;
        3) MODE="ultra" ;;
        *) MODE="standard" ;;
    esac
}

#------------ swap（容错） ------------
setup_swap() {
    section "虚拟内存 (swap)"
    [ $CAN_SWAP -eq 0 ] && { warn "环境不支持 swap，跳过"; return; }
    local cur=$(free -m | awk '/Swap:/ {print $2}')
    local sz
    if   [[ $MEM_TOTAL_MB -le 128 ]]; then sz=256
    elif [[ $MEM_TOTAL_MB -le 256 ]]; then sz=512
    elif [[ $MEM_TOTAL_MB -le 512 ]]; then sz=1024
    elif [[ $MEM_TOTAL_MB -le 1024 ]]; then sz=2048
    elif [[ $MEM_TOTAL_MB -le 2048 ]]; then sz=4096
    elif [[ $MEM_TOTAL_MB -le 4096 ]]; then sz=6144
    else sz=8192
    fi
    [[ "$MODE" == "ultra" ]] && sz=$(( sz + 1024 ))
    [ $cur -ge $sz ] && { info "swap 充足，跳过"; return; }
    [ $DISK_FREE_GB -lt $(( (sz+1023)/1024 )) ] && sz=$(( DISK_FREE_GB*1024 - 512 ))
    [ $sz -le 128 ] && { warn "磁盘不足，跳过 swap"; return; }

    info "尝试创建 ${sz}MB swap..."
    [ -f /swapfile ] && swapoff /swapfile 2>/dev/null && rm -f /swapfile
    fallocate -l ${sz}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$sz status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1 || { warn "mkswap 失败，跳过"; rm -f /swapfile; return; }
    if swapon /swapfile 2>/dev/null; then
        info "swap 创建成功"
        grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    else
        warn "swapon 失败，清理"
        rm -f /swapfile
    fi
}

#------------ 模块加载 ------------
load_modules() {
    section "内核模块与算法"
    QDISC="pfifo_fast"
    if [ $FQ_SUPPORT -eq 1 ]; then
        QDISC="fq"
        echo "sch_fq" > /etc/modules-load.d/optimizer-fq.conf 2>/dev/null || true
    fi

    if echo "$AVAILABLE_CC" | grep -qw bbr; then
        CC_ALGO="bbr"
        modprobe tcp_bbr 2>/dev/null || true
    else
        CC_ALGO=$(echo "$AVAILABLE_CC" | awk '{print $1}')
    fi
    info "使用: ${CC_ALGO} + ${QDISC}"
}

#------------ 智能参数探测与应用 ------------
# 全局数组存储最终要写入的配置
declare -A FINAL_SYSCTL    # key => value
FAILED_KEYS=()

# 探测一个 sysctl 键是否可写，并尝试设置值（支持 fallback）
try_sysctl() {
    local key="$1"
    local val="$2"
    local fallback="$3"   # 可选：如果失败，用这个值再试
    local proc_path="/proc/sys/${key//./\}"

    # 文件存在？
    if [ ! -e "$proc_path" ]; then
        FAILED_KEYS+=("$key (文件不存在)")
        return 1
    fi

    # 可写？
    if [ ! -w "$proc_path" ]; then
        FAILED_KEYS+=("$key (只读)")
        return 1
    fi

    # 尝试写入
    if echo "$val" > "$proc_path" 2>/dev/null; then
        FINAL_SYSCTL["$key"]="$val"
        return 0
    fi

    # 如果有 fallback，递归尝试
    if [ -n "$fallback" ]; then
        warn "$key=$val 失败，尝试 $fallback"
        if echo "$fallback" > "$proc_path" 2>/dev/null; then
            FINAL_SYSCTL["$key"]="$fallback"
            return 0
        fi
    fi

    # 彻底失败
    FAILED_KEYS+=("$key (值无效或权限不足)")
    return 1
}

# 尝试 rmem_max/wmem_max，自动探测上限
try_buffer_max() {
    local key="$1"
    local desired="$2"
    local proc_path="/proc/sys/${key//./\}"

    [ ! -e "$proc_path" ] && { FAILED_KEYS+=("$key (不存在)"); return 1; }
    [ ! -w "$proc_path" ] && { FAILED_KEYS+=("$key (只读)"); return 1; }

    # 二分法探测上限：从 desired 开始，失败则减半，直到成功
    local val=$desired
    while [ $val -ge 4096 ]; do
        if echo "$val" > "$proc_path" 2>/dev/null; then
            FINAL_SYSCTL["$key"]="$val"
            info "$key = $val (探测成功)"
            return 0
        fi
        val=$(( val / 2 ))
    done
    FAILED_KEYS+=("$key (无法设置)")
    return 1
}

apply_all_params() {
    section "参数探测与应用"

    # 先设置拥塞控制（可能已可用）
    try_sysctl "net.ipv4.tcp_congestion_control" "$CC_ALGO"
    try_sysctl "net.ipv4.tcp_ecn" "0"

    # 缓冲区
    local rmax wmax rmem wmem tcp_mem_val
    local mem=$MEM_TOTAL_MB
    local syn_retries_val=2 tcp_retries2_val=5 early_retrans_val=2
    local limit_output=0 notsent_lowat=131072
    local file_max=65536 somaxconn=32768 backlog=16384 syn_backlog=16384
    local tw_buckets=8192 max_orphans=32768

    # 根据内存计算理想值
    if [ $mem -le 128 ]; then
        rmax=2097152; wmax=2097152
        rmem="4096 32768 2097152"; wmem="4096 16384 2097152"
        tcp_mem_val="4096 8192 16384"
        file_max=32768; somaxconn=2048; backlog=1024; syn_backlog=1024
        tw_buckets=1024; max_orphans=4096; limit_output=65536; notsent_lowat=4096
        syn_retries_val=3; tcp_retries2_val=8; early_retrans_val=1
    elif [ $mem -le 256 ]; then
        rmax=4194304; wmax=4194304
        rmem="4096 65536 4194304"; wmem="4096 32768 4194304"
        tcp_mem_val="8192 16384 32768"
        file_max=32768; somaxconn=4096; backlog=2048; syn_backlog=2048
        tw_buckets=2048; max_orphans=8192; limit_output=131072; notsent_lowat=8192
        syn_retries_val=3; tcp_retries2_val=8; early_retrans_val=1
    elif [ $mem -le 512 ]; then
        rmax=8388608; wmax=8388608
        rmem="4096 131072 8388608"; wmem="4096 65536 8388608"
        tcp_mem_val="16384 32768 65536"
        file_max=65536; somaxconn=8192; backlog=4096; syn_backlog=4096
        tw_buckets=4096; max_orphans=16384; limit_output=262144; notsent_lowat=16384
        syn_retries_val=2; tcp_retries2_val=6; early_retrans_val=1
    elif [ $mem -le 1024 ]; then
        rmax=16777216; wmax=16777216
        rmem="4096 131072 16777216"; wmem="4096 65536 16777216"
        tcp_mem_val="32768 65536 131072"
        file_max=65536; somaxconn=32768; backlog=16384; syn_backlog=16384
        tw_buckets=8192; max_orphans=32768; limit_output=262144; notsent_lowat=32768
        syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
    elif [ $mem -le 4096 ]; then
        rmax=67108864; wmax=67108864
        rmem="4096 262144 67108864"; wmem="4096 131072 67108864"
        tcp_mem_val="131072 262144 524288"
        file_max=1000000; somaxconn=65535; backlog=65535; syn_backlog=65535
        tw_buckets=16384; max_orphans=65536; limit_output=0; notsent_lowat=131072
        syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
    else
        rmax=134217728; wmax=134217728
        rmem="4096 131072 134217728"; wmem="4096 65536 134217728"
        tcp_mem_val="524288 786432 1048576"
        file_max=2000000; somaxconn=65535; backlog=262144; syn_backlog=131072
        tw_buckets=32768; max_orphans=131072; limit_output=0; notsent_lowat=131072
        syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
    fi

    # 激进模式上调
    if [ "$MODE" == "ultra" ]; then
        if [ $mem -ge 1024 ]; then
            rmax=$(( rmax * 2 )); wmax=$(( wmax * 2 ))
            rmem="4096 $(( $(echo $rmem | awk '{print $2}') * 2 )) $rmax"
            wmem="4096 $(( $(echo $wmem | awk '{print $2}') * 2 )) $wmax"
            tcp_mem_val="$(( $(echo $tcp_mem_val | awk '{print $1}') * 2 )) $(( $(echo $tcp_mem_val | awk '{print $2}') * 2 )) $(( $(echo $tcp_mem_val | awk '{print $3}') * 2 ))"
            syn_retries_val=1; tcp_retries2_val=3; early_retrans_val=3
        fi
    fi

    # 逐个尝试设置
    try_buffer_max "net.core.rmem_max" $rmax
    try_buffer_max "net.core.wmem_max" $wmax
    try_sysctl "net.ipv4.tcp_rmem" "$rmem"
    try_sysctl "net.ipv4.tcp_wmem" "$wmem"
    try_sysctl "net.ipv4.tcp_mem" "$tcp_mem_val" "$tcp_mem_val"  # will fail if missing
    try_sysctl "net.ipv4.tcp_limit_output_bytes" "$limit_output"
    try_sysctl "net.ipv4.tcp_notsent_lowat" "$notsent_lowat"
    try_sysctl "net.ipv4.tcp_window_scaling" "1"
    try_sysctl "net.ipv4.tcp_adv_win_scale" "1"
    try_sysctl "net.ipv4.tcp_slow_start_after_idle" "0"
    try_sysctl "net.ipv4.tcp_no_metrics_save" "1"
    try_sysctl "net.ipv4.tcp_mtu_probing" "1"
    try_sysctl "net.ipv4.tcp_sack" "1"
    try_sysctl "net.ipv4.tcp_dsack" "1"
    try_sysctl "net.ipv4.tcp_fack" "1"
    try_sysctl "net.ipv4.tcp_reordering" "3"
    try_sysctl "net.ipv4.tcp_early_retrans" "$early_retrans_val"
    try_sysctl "net.ipv4.tcp_syn_retries" "$syn_retries_val"
    try_sysctl "net.ipv4.tcp_synack_retries" "$syn_retries_val"
    try_sysctl "net.ipv4.tcp_retries1" "$syn_retries_val"
    try_sysctl "net.ipv4.tcp_retries2" "$tcp_retries2_val"
    try_sysctl "net.ipv4.tcp_timestamps" "1"
    try_sysctl "net.ipv4.tcp_fin_timeout" "10"
    try_sysctl "net.ipv4.tcp_max_tw_buckets" "$tw_buckets"
    try_sysctl "net.ipv4.tcp_tw_reuse" "1"
    try_sysctl "net.ipv4.ip_local_port_range" "1024 65535"
    try_sysctl "net.ipv4.tcp_max_orphans" "$max_orphans"
    try_sysctl "net.core.somaxconn" "$somaxconn"
    try_sysctl "net.core.netdev_max_backlog" "$backlog"
    try_sysctl "net.ipv4.tcp_max_syn_backlog" "$syn_backlog"
    try_sysctl "net.ipv4.tcp_syncookies" "1"
    try_sysctl "net.ipv4.tcp_abort_on_overflow" "0"
    try_sysctl "net.ipv4.ip_forward" "1"
    try_sysctl "net.ipv4.tcp_moderate_rcvbuf" "1"
    try_sysctl "fs.file-max" "$file_max"
    try_sysctl "vm.swappiness" "10"
    try_sysctl "vm.vfs_cache_pressure" "50"

    # 生成精简版 sysctl.conf（只包含成功项）
    local bak="/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/sysctl.conf "$bak" 2>/dev/null || true
    info "备份: $bak"

    cat > /etc/sysctl.conf << EOF
# Generated by VPS Optimizer v2.5
# Mode: ${MODE} | Arch: ${ARCH_TYPE} | Cores: ${CPU_CORES} | Mem: ${MEM_TOTAL_MB}MB
# Backup: $bak
# Only successfully applied parameters are listed.
EOF
    for key in "${!FINAL_SYSCTL[@]}"; do
        echo "$key = ${FINAL_SYSCTL[$key]}" >> /etc/sysctl.conf
    done

    # 网卡队列
    if [ $FQ_SUPPORT -eq 1 ]; then
        tc qdisc replace dev "$IFACE" root fq 2>/dev/null && info "网卡队列 -> fq" || warn "fq 设置失败"
    fi
    ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null || true
}

#------------ 总结 ------------
final_summary() {
    section "优化结果汇总"
    echo ""
    # 成功项
    echo -e "  ${GREEN}成功应用的参数 (${#FINAL_SYSCTL[@]} 项):${NC}"
    for key in $(echo "${!FINAL_SYSCTL[@]}" | tr ' ' '\n' | sort); do
        echo -e "    ${key} = ${FINAL_SYSCTL[$key]}"
    done

    # 失败项
    if [ ${#FAILED_KEYS[@]} -gt 0 ]; then
        echo ""
        echo -e "  ${RED}无法应用的参数 (${#FAILED_KEYS[@]} 项):${NC}"
        for msg in "${FAILED_KEYS[@]}"; do
            echo -e "    - $msg"
        done
    fi

    echo ""
    info "建议重启代理服务: systemctl restart v2ray"
    info "回滚: cp $bak /etc/sysctl.conf && sysctl -p"
}

#-----------------------------------------------------------------------------
main() {
    print_header
    detect_environment
    print_system_info
    recommend_mode
    read_choice
    [ "$MODE" == "exit" ] && { info "已退出"; exit 0; }

    echo ""
    echo -e "${YELLOW}开始 [${MODE}] 模式优化...${NC}"
    sleep 1

    setup_swap
    load_modules
    apply_all_params
    final_summary
}

main "$@"
