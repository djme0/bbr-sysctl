#!/usr/bin/env bash
#=============================================================================
# VPS Network Optimizer v2.1 — 交互菜单版
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/djme0/djme0-bbr-sysctl/main/vps-optimizer.sh | sudo bash
#   或下载后执行： sudo bash vps-optimizer.sh
#=============================================================================
set -e

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo ""; echo -e "${CYAN}===== $1 =====${NC}"; }

must_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 用户运行"
        exit 1
    fi
}

# 尝试从终端读取输入（支持 curl | bash 管道执行）
read_input() {
    local prompt="$1"
    local default="$2"
    local input
    if [ -t 0 ]; then
        # 正常交互
        read -p "$prompt" input
    else
        # 从 /dev/tty 读取
        read -p "$prompt" input < /dev/tty
    fi
    echo "${input:-$default}"
}

#------------ 硬件探测 ------------
detect_system() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)  ARCH_TYPE="x86_64" ;;
        aarch64|arm64) ARCH_TYPE="arm64"  ;;
        *)             ARCH_TYPE="other"  ;;
    esac
    CPU_CORES=$(nproc)
    MEM_TOTAL_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    DISK_FREE_GB=$(df -BG / | awk 'NR==2 {print int($4)}')
    IFACE=$(ip route get 1 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$IFACE" ]] && IFACE="eth0"
    AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    section "系统信息"
    info "架构: ${ARCH_TYPE} | 核心数: ${CPU_CORES} | 物理内存: ${MEM_TOTAL_MB}MB"
    info "磁盘剩余: ${DISK_FREE_GB}G | 主网卡: ${IFACE}"
    info "可用拥塞控制: ${AVAILABLE_CC}"
}

#------------ 虚拟内存 ------------
SWAP_FILE="/swapfile"
setup_swap() {
    section "虚拟内存 (swap)"
    local current_swap=$(free -m | awk '/Swap:/ {print $2}')
    local swap_size
    if   [[ $MEM_TOTAL_MB -le 1024 ]]; then swap_size=2048
    elif [[ $MEM_TOTAL_MB -le 2048 ]]; then swap_size=4096
    elif [[ $MEM_TOTAL_MB -le 4096 ]]; then swap_size=6144
    else swap_size=8192
    fi

    # 激进模式可以要求更大 swap，这里统一再加 1G
    [[ "$MODE" == "ultra" ]] && swap_size=$(( swap_size + 1024 ))

    if [[ $current_swap -ge $swap_size ]]; then
        info "当前 swap 足够 (${current_swap}MB >= ${swap_size}MB)，跳过创建"
        return
    fi
    if [[ $DISK_FREE_GB -lt $(( (swap_size + 1023) / 1024 )) ]]; then
        swap_size=$(( DISK_FREE_GB * 1024 - 512 ))
        [[ $swap_size -le 128 ]] && { warn "磁盘空间过小，放弃 swap"; return; }
    fi
    info "正在创建 ${swap_size}MB swap 文件 ..."
    [[ -f "$SWAP_FILE" ]] && swapoff "$SWAP_FILE" && rm -f "$SWAP_FILE"
    fallocate -l ${swap_size}M "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$swap_size status=none
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" > /dev/null
    swapon "$SWAP_FILE"
    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    info "swap 创建完成，当前总量: $(free -m | awk '/Swap:/ {print $2}')MB"
}

#------------ 内核模块 ------------
load_modules() {
    section "内核模块"
    if modprobe sch_fq 2>/dev/null; then
        info "sch_fq 模块已加载"
        echo "sch_fq" > /etc/modules-load.d/optimizer-fq.conf
    else
        warn "sch_fq 不可用 (内核可能不支持)"
    fi

    if echo "$AVAILABLE_CC" | grep -qw bbrplus; then
        CC_ALGO="bbrplus"
        modprobe tcp_bbrplus 2>/dev/null || { CC_ALGO="bbr"; modprobe tcp_bbr; }
    else
        CC_ALGO="bbr"
        modprobe tcp_bbr 2>/dev/null
    fi
    echo "tcp_${CC_ALGO}" > /etc/modules-load.d/optimizer-cc.conf
    info "选择的拥塞控制: ${CC_ALGO}"
}

#------------ 生成 sysctl 配置 ------------
generate_sysctl() {
    section "生成 sysctl 配置"
    local mem=$MEM_TOTAL_MB
    local rmem_max wmem_max tcp_rmem tcp_wmem tcp_mem
    local file_max somaxconn backlog syn_backlog tw_buckets max_orphans limit_output notsent_lowat
    local tcp_retries2_val syn_retries_val early_retrans_val

    # 标准/激进参数表
    if [[ "$MODE" == "ultra" ]]; then
        # -------- 激进模式：不顾一切抢带宽 --------
        if [[ $mem -le 1024 ]]; then
            rmem_max=33554432; wmem_max=33554432
            tcp_rmem="4096 262144 33554432"
            tcp_wmem="4096 131072 33554432"
            tcp_mem="65536 262144 524288"
            file_max=65536; somaxconn=65535; backlog=32768; syn_backlog=32768
            tw_buckets=16384; max_orphans=65536; limit_output=0; notsent_lowat=131072
            syn_retries_val=1; tcp_retries2_val=3; early_retrans_val=3
            warn "内存 ≤1G 但启用激进模式，有 OOM 风险！"
        elif [[ $mem -le 4096 ]]; then
            rmem_max=134217728; wmem_max=134217728
            tcp_rmem="4096 524288 134217728"
            tcp_wmem="4096 262144 134217728"
            tcp_mem="262144 786432 1572864"
            file_max=1000000; somaxconn=65535; backlog=65535; syn_backlog=131072
            tw_buckets=16384; max_orphans=131072; limit_output=0; notsent_lowat=262144
            syn_retries_val=1; tcp_retries2_val=3; early_retrans_val=3
        else
            rmem_max=268435456; wmem_max=268435456
            tcp_rmem="4096 1048576 268435456"
            tcp_wmem="4096 524288 268435456"
            tcp_mem="1048576 1572864 2097152"
            file_max=2000000; somaxconn=65535; backlog=262144; syn_backlog=131072
            tw_buckets=32768; max_orphans=262144; limit_output=0; notsent_lowat=262144
            syn_retries_val=1; tcp_retries2_val=2; early_retrans_val=3
        fi
    else
        # -------- 标准优化（原有分档）--------
        if [[ $mem -le 1024 ]]; then
            rmem_max=16777216; wmem_max=16777216
            tcp_rmem="4096 131072 16777216"
            tcp_wmem="4096 65536 16777216"
            tcp_mem="32768 65536 131072"
            file_max=65536; somaxconn=32768; backlog=16384; syn_backlog=16384
            tw_buckets=8192; max_orphans=32768; limit_output=262144; notsent_lowat=32768
            syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
        elif [[ $mem -le 4096 ]]; then
            rmem_max=67108864; wmem_max=67108864
            tcp_rmem="4096 262144 67108864"
            tcp_wmem="4096 131072 67108864"
            tcp_mem="131072 262144 524288"
            file_max=1000000; somaxconn=65535; backlog=65535; syn_backlog=65535
            tw_buckets=16384; max_orphans=65536; limit_output=0; notsent_lowat=131072
            syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
        else
            rmem_max=134217728; wmem_max=134217728
            tcp_rmem="4096 131072 134217728"
            tcp_wmem="4096 65536 134217728"
            tcp_mem="524288 786432 1048576"
            file_max=2000000; somaxconn=65535; backlog=262144; syn_backlog=131072
            tw_buckets=32768; max_orphans=131072; limit_output=0; notsent_lowat=131072
            syn_retries_val=2; tcp_retries2_val=5; early_retrans_val=2
        fi
    fi

    # 备份原文件
    local bak="/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/sysctl.conf "$bak" 2>/dev/null || true
    info "原有配置备份至: $bak"

    # 写入新配置
    cat > /etc/sysctl.conf << EOF
# Generated by VPS Optimizer v2.1 (https://github.com/djme0/djme0-bbr-sysctl)
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
    info "新的 /etc/sysctl.conf 已生成"
}

#------------ 应用配置 ------------
apply_config() {
    section "应用配置"
    sysctl -p /etc/sysctl.conf > /dev/null 2>&1 || warn "部分参数可能因内核限制未生效（可忽略）"
    info "sysctl 参数已加载"

    if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
        info "网卡 $IFACE 根队列设置为 fq"
    else
        warn "网卡 $IFACE 设置 fq 失败"
    fi
    ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null
    info "网卡发送队列长度已提高"
}

#------------ 显示最终信息 ------------
final_summary() {
    section "优化完成"
    echo -e "  ${CYAN}拥塞控制  ${NC}: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "  ${CYAN}默认 Qdisc${NC}: $(sysctl -n net.core.default_qdisc)"
    echo -e "  ${CYAN}ECN       ${NC}: $(sysctl -n net.ipv4.tcp_ecn)"
    echo -e "  ${CYAN}Swap 总量 ${NC}: $(free -m | awk '/Swap:/ {print $2}') MB"
    echo -e "  ${CYAN}备份文件  ${NC}: $bak"
    echo ""
    info "请重启你的代理/转发服务以使新连接使用优化参数"
    echo -e "  ${YELLOW}systemctl restart v2ray${NC} (或其他服务名)"
    echo ""
    info "如需回滚，执行："
    echo -e "  cp $bak /etc/sysctl.conf && sysctl -p"
    echo ""
}

#-----------------------------------------------------------------------------
# 主菜单 + 流程
#-----------------------------------------------------------------------------
main_menu() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       VPS Network Optimizer v2.1          ║${NC}"
    echo -e "${CYAN}║     硬核优化 · 菜单交互 · 抢带宽         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "请选择优化模式："
    echo "  1) 退出 (不执行任何操作)"
    echo "  2) 标准优化 (平衡性能与安全)"
    echo "  3) 激进模式 (不顾邻居死活，最大化带宽，可能 OOM)"
    echo ""
    local choice=$(read_input "输入数字 [2]: " "2")
    case $choice in
        1) 
            info "已退出，未作任何更改。"
            exit 0
            ;;
        2)
            MODE="standard"
            info "即将执行【标准优化】..."
            ;;
        3)
            MODE="ultra"
            warn "激进模式将在小内存机器上启用极大缓冲，可能导致 OOM！"
            local confirm=$(read_input "确认继续？(y/N): " "n")
            if [[ ! $confirm =~ ^[Yy]$ ]]; then
                info "已取消。"
                exit 0
            fi
            info "开始执行【激进模式】优化..."
            ;;
        *)
            warn "无效输入，默认选择标准优化"
            MODE="standard"
            ;;
    esac
}

#------------ 主执行函数 ------------
run_optimization() {
    must_root
    detect_system
    setup_swap
    load_modules
    generate_sysctl
    apply_config
    final_summary
}

#-----------------------------------------------------------------------------
main() {
    main_menu
    run_optimization
}

main
