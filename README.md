# VPS Network Optimizer

专为 VPS 运维设计的自动化网络优化脚本。

## 功能
- 自动检测 CPU 核心数 / 物理内存 / 架构 (ARM / x86_64)
- 自动创建 / 调整 swap 大小
- 根据内存大小动态生成激进但安全的 sysctl 配置
- 自动加载 BBR / BBRplus + fq qdisc
- 备份原有配置，可安全回滚

## 一键运行
```bash
curl -fsSL https://raw.githubusercontent.com/djme0/bbr-sysctl/main/vps-optimizer.sh | sudo bash
