#!/usr/bin/env bash
# tcpfit — 单机 TCP 调优代理
#
# 纯 bash, 除 iperf3(仅 sweep 需要) 外无依赖, 可在任何最小化 VPS 上直接跑.
# 所有"该设多少"的判断都由实测或机器规格推导, 不使用抄来的固定值.
#
# 用法:
#   tcpfit.sh                               交互式菜单（不带参数即可, 推荐）
#   tcpfit.sh detect                        输出机器画像
#   tcpfit.sh probe  --peer HOST            探测可用带宽(虚拟网卡读不到标称值时用)
#   tcpfit.sh tune   [选项]                 应用基础调优
#   tcpfit.sh sweep  --peer HOST [选项]     实测限速器拐点 (-4/-6 指定协议族, 默认 -4)
#   tcpfit.sh shape  --rate N | --off       应用/移除出向整形
#   tcpfit.sh harden --swap 2G              加 swap（小内存机防止进程被杀）
#   tcpfit.sh verify [--peer HOST]          验证当前状态
#   tcpfit.sh status                        显示当前配置
#   tcpfit.sh rollback                      回滚到调优前
#
# 退出码: 0 成功 / 1 参数或环境错误 / 2 实测失败

set -uo pipefail
umask 022   # 固定权限: 生成的脚本和配置不能因为宽松 umask 变成他人可写

VERSION="0.5.3"
STATE_DIR="/var/lib/tcpfit"
SYSCTL_FILE="/etc/sysctl.d/99-tcpfit.conf"
QDISC_SCRIPT="/usr/local/sbin/tcpfit-qdisc.sh"
QDISC_UNIT="/etc/systemd/system/tcpfit-qdisc.service"
ROUTE_HOOK="/etc/networkd-dispatcher/routable.d/50-tcpfit-initcwnd"
SNAPSHOT="$STATE_DIR/pre-tune.snapshot"
FACTS="$STATE_DIR/facts"

# ── 输出 ────────────────────────────────────────────────────────────────────
# 配色对齐 x-ui, 用户在同一台机器上看到的风格一致
if [ -t 1 ]; then
  green=$'\033[0;32m'; red=$'\033[0;31m'; yellow=$'\033[0;33m'
  blue=$'\033[0;36m';  bold=$'\033[1m';   plain=$'\033[0m'
else
  green=''; red=''; yellow=''; blue=''; bold=''; plain=''
fi
_c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
info(){ printf '%s %s\n' "$(_c '0;36' '[*]')" "$*"; }
ok(){   printf '%s %s\n' "$(_c '0;32' '[+]')" "$*"; }
warn(){ printf '%s %s\n' "$(_c '0;33' '[!]')" "$*" >&2; }
die(){  printf '%s %s\n' "$(_c '0;31' '[x]')" "$*" >&2; exit "${2:-1}"; }

# 按显示宽度对齐：CJK 占 2 列, printf 的 %-Ns 按字节算会错位.
# 不能依赖 awk 的多字节支持 —— mawk(Debian 默认) 没有, 会把 3 字节的中文算成 3 个字符.
# 这里直接按 UTF-8 前导字节判断：ASCII=1列, 2字节序列=1列, 3字节及以上=2列, 续字节=0列.
_dispw(){
  printf '%s' "$1" | LC_ALL=C od -An -tu1 2>/dev/null | awk '
    {for(i=1;i<=NF;i++){b=$i
       if(b<128)            n++          # ASCII
       else if(b<192)       continue     # 续字节, 不计宽
       else if(b<224)       n++          # 2 字节序列(拉丁扩展等)
       else if(b==226){ nx=$(i+1); if(nx==148||nx==149){ n++; i+=2; continue } n+=2 }
       else                 n+=2         # 3 字节及以上(CJK、全角符号)
    }} END{print n+0}'
}
kv(){ local w; w=$(_dispw "$1"); printf '  %s%*s %s\n' "$1" $(( 20 - w )) "" "$2"; }
# 把字符串按「显示宽度」补齐到 N 列, 供手工排表用
_pad(){  local w; w=$(_dispw "$1"); printf '%s%*s' "$1" $(( $2 - w )) ""; }
_rpad(){ local w; w=$(_dispw "$1"); printf '%*s%s' $(( $2 - w )) "" "$1"; }
# 「确认」和「结果」里的两列排版
_conf(){ printf '      %s %s\n' "$(_pad "$1" 14)" "$2"; }

# 同时跑两个实例会同时抢 qdisc、快照和 sysctl. 用文件锁串行化.
LOCK_FILE="/var/lock/tcpfit.lock"
take_lock(){
  command -v flock >/dev/null || return 0
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
  # 注意不能写成 exec 9>FILE 2>/dev/null —— 那个 2>/dev/null 会被 exec 当成
  # 永久重定向, 把整个脚本的 stderr 都吞掉, 所有 die/warn 就都看不见了.
  [ -w "$(dirname "$LOCK_FILE")" ] || return 0
  exec 9>"$LOCK_FILE" || return 0
  flock -n 9 && return 0

  # 锁被占: 可能真有另一个在跑, 也可能是上次异常退出(SSH 断线/被 kill)卡住了.
  # 给出持有者和已运行时长, 让用户能判断, 并提供一键结束 —— 光说"等它结束"
  # 遇到卡死的情况没有出路. 而且 bash <(curl ...) 起的进程 cmdline 是
  # /dev/fd/63, 用 pkill -f tcpfit 根本找不到它.
  local pids age
  # 排除自己 —— 上面已经 exec 9> 打开了锁文件, 不排掉会把自己也列成持有者
  pids=$(fuser "$LOCK_FILE" 2>/dev/null | tr -s ' ' | tr ' ' '\n' | grep -vx "$$" | grep -x '[0-9]*' | tr '\n' ' ')
  [ -n "$pids" ] || pids=$(command -v lsof >/dev/null && lsof -t "$LOCK_FILE" 2>/dev/null | grep -vx "$$" | tr '\n' ' ')
  warn "另一个 tcpfit 正在运行（锁: $LOCK_FILE）"
  if [ -n "$pids" ]; then
    echo "      持有者:"
    for _p in $pids; do
      age=$(ps -o etime= -p "$_p" 2>/dev/null | tr -d ' ')
      [ -n "$age" ] && printf '        PID %-8s 已运行 %s\n' "$_p" "$age"
    done
  fi
  echo "      跑得太久多半是上次异常退出卡住了."
  echo
  # 拿不到 PID 就没法安全地只杀它们, 不如让用户自己处理
  [ -n "$pids" ] || die "查不到锁的持有者, 手动检查: fuser -v $LOCK_FILE"
  if confirm "  结束它并继续？" n; then
    exec 9>&-                                   # 先松开自己, 否则会把自己一起杀掉
    # 只杀最初记录的那几个 PID. 绝不能第二次去查锁文件 ——
    # 旧实例收到 TERM 退出后, 别的新实例可能在这 3 秒里拿到锁,
    # 再查一次就会把那个无辜的新实例 KILL 掉(实测复现过, 新实例退出码 137).
    kill -TERM $pids 2>/dev/null            # 先 TERM, 让对方的 trap 有机会恢复 qdisc
    sleep 3
    for _p in $pids; do
      kill -0 "$_p" 2>/dev/null && kill -KILL "$_p" 2>/dev/null
    done
    sleep 1
    reap_iperf
    exec 9>"$LOCK_FILE" || return 0
    flock -n 9 || die "锁仍被占用, 手动查看: fuser -v $LOCK_FILE"
    ok "已结束, 继续"
    return 0
  fi
  die "已取消"
}

need_root(){ [ "$(id -u)" = 0 ] || die "需要 root 权限"; }

# 转圈. 长操作(iperf3 一跑十几秒)不给反馈的话用户会以为卡死了.
# 非交互环境(管道/日志)不画, 避免把日志刷满控制字符.
SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
spin_wait(){   # spin_wait <pid> <描述>
  local pid="$1" msg="$2" i=0
  if [ ! -t 2 ]; then wait "$pid" 2>/dev/null; return $?; fi
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  \033[0;36m%s\033[0m %s' "${SPIN_FRAMES:$((i++%10)):1}" "$msg" >&2
    sleep 0.12
  done
  printf '\r\033[K' >&2
  wait "$pid" 2>/dev/null
}
# ── 流量计量 ──────────────────────────────────────────────────────────────
# 读网卡字节计数器. 比按速率估算准 —— 它把重传、协议开销、握手全算进去了.
TRAFFIC_RX0=""; TRAFFIC_TX0=""
traffic_mark(){
  local i; i=$(detect_iface)
  TRAFFIC_RX0=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null || echo 0)
  TRAFFIC_TX0=$(cat "/sys/class/net/$i/statistics/tx_bytes" 2>/dev/null || echo 0)
}
traffic_report(){
  [ -n "$TRAFFIC_TX0" ] || return 0
  local i rx tx drx dtx; i=$(detect_iface)
  rx=$(cat "/sys/class/net/$i/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/$i/statistics/tx_bytes" 2>/dev/null || echo 0)
  drx=$(( rx - TRAFFIC_RX0 )); dtx=$(( tx - TRAFFIC_TX0 ))
  [ "$drx" -lt 0 ] && drx=0; [ "$dtx" -lt 0 ] && dtx=0
  echo
  printf '  %s本次测试消耗流量%s\n' "$bold" "$plain"
  rule
  awk -v tx="$dtx" -v rx="$drx" '
    function h(b){ if(b>=1073741824) return sprintf("%.2f GB", b/1073741824); return sprintf("%.0f MB", b/1048576) }
    BEGIN{
      printf "  %-16s %s\n","出向 (上传)", h(tx)
      printf "  %-16s %s\n","入向 (下载)", h(rx)
      printf "  %-16s %s\n","双向合计", h(tx+rx)
    }'
  rule
}

rule(){ printf '  \033[2m%s\033[0m\n' "────────────────────────────────────────────────"; }
step(){ printf '\n  \033[1;36m▸ %s\033[0m\n' "$*"; }

# 用 bash <(curl ...) 一条命令跑时, $0 是临时 fd, 脚本一退出就没了.
# 这里把自己装到系统里, 以后想回滚/查状态还能找到.
# 测速走哪个协议族. 默认 IPv4 —— 双栈机器上 v4 和 v6 到同一个对端的延迟可能差很多,
# 实测见过同城对端 v4 0.8ms / v6 93ms, 按 v6 的 RTT 选对端会把最好的那个判成"太远".
# 更麻烦的是 ping 和 iperf3 各自独立解析, 可能一个走 v4 一个走 v6 ——
# 那样挑选依据和实际测量根本不是同一条链路.
IP_FAMILY="${IP_FAMILY:--4}"

# 按当前协议族把主机名解析成字面地址. bash 的 /dev/tcp 没法指定协议族,
# 只能先解析好再连. 注意 v6 字面量不能加方括号, bash 认不了.
#
# -6 那支必须滤掉 ::ffff: 开头的 v4 映射地址 —— getent ahostsv6 对只有 A 记录的
# 主机也会返回结果(如 ::ffff:20.205.243.166), 而 iperf3 -6 连这种地址还会成功.
# 不滤的话: 用户选了 v6, 整个测试悄悄跑在 IPv4 上, 一句提示都没有.
resolve_ip(){   # resolve_ip <主机名>
  case "$IP_FAMILY" in
    -6) getent ahostsv6 "$1" 2>/dev/null | awk '/STREAM/ && $1 !~ /^::ffff:/ {print $1; exit}' ;;
    *)  getent ahostsv4 "$1" 2>/dev/null | awk '/STREAM/{print $1; exit}' ;;
  esac
}
# 端口探测: 解析不出对应协议族的地址就直接算不可达
probe_port(){   # probe_port <主机> <端口> [超时秒]
  local ip; ip=$(resolve_ip "$1"); [ -n "$ip" ] || return 1
  timeout "${3:-6}" bash -c "cat < /dev/null > /dev/tcp/${ip}/${2}" 2>/dev/null
}

# 对端 iperf3 实例的端口范围. Leaseweb/OVH 开 5201-5210, Clouvider 开 5200-5209 ——
# 所以 5200 也得在表里. 放末尾: 放开头会让 16 个 Leaseweb/OVH 节点每次都先白撞一下.
PORT_POOL="5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200"

# 把首选端口排到表最前面, 其余保持原序. run_iperf 和选对端共用一份顺序.
port_order(){   # port_order <首选端口>
  local p out="$1"
  for p in $PORT_POOL; do [ "$p" = "$1" ] || out="$out $p"; done
  echo "$out"
}

# 选对端时的预检端口. 只探 5201 会出大事 —— 5201 是 iperf3 默认端口, 有机房
# 专门封它防测速滥用. 实测过一台客户机器(Debian 13, 依赖齐全, 无本地防火墙):
# 出站 5201 被单独封死(对 6 个不同目标 0/5), 而 5200/5202/5210/5211/6201 全是 5/5,
# 结果 18 个节点全被判成 "port closed", 工具完全不可用, 最后那句
# "公共测速服务器暂时都不可用" 还把责任推给了完全无辜的对端.
PROBE_PORTS="5201 5202 5203 5200"
PROBE_HIT=""        # 上一个探通的端口. 出站封锁对所有节点一致, 记住能省掉 17 次重复失败
PROBE_PORT_OK=""    # probe_peer_port 的结果

# 不能用 $(...) 取结果 —— 命令替换是子 shell, PROBE_HIT 记不住, 缓存就失效了.
probe_peer_port(){  # probe_peer_port <主机>  -> 成功则 PROBE_PORT_OK=端口
  local try seen=""
  PROBE_PORT_OK=""
  for try in $PROBE_HIT $PROBE_PORTS; do
    case " $seen " in *" $try "*) continue ;; esac      # PROBE_HIT 可能和表里重复
    seen="$seen $try"
    probe_port "$1" "$try" 4 || continue
    PROBE_HIT="$try"; PROBE_PORT_OK="$try"; return 0
  done
  return 1
}

# 本机有没有可用的 IPv4 出网能力. 纯 v6 机器要自动走 v6, 不能傻等 v4 超时.
have_ipv4(){
  # 不接 grep -q：pipefail 下多地址输出会让 ip 在 grep 提前退出后收到 SIGPIPE, 反而误判为失败.
  [ -n "$(ip -4 route show default 2>/dev/null)" ] || return 1
  [ -n "$(ip -4 addr show scope global 2>/dev/null)" ] || return 1
}

# 本机有没有可用的 IPv6 出网能力. 光有地址不算 —— 很多机器配了 v6 地址但没路由.
have_ipv6(){
  [ -n "$(ip -6 route show default 2>/dev/null)" ] || return 1
  [ -n "$(ip -6 addr show scope global 2>/dev/null)" ] || return 1
}

PEER_PORT="${PEER_PORT:-5201}"   # 选定对端时确定的可用端口
WIZARD=0                         # 一键流程内为 1：子命令只输出执行日志, 收尾统一由 wizard 打印
# 装成不带扩展名的 tcpfit, 放 /usr/local/bin —— 用户敲 `tcpfit` 就能进菜单.
# 不用 /usr/local/sbin 是因为它不在普通用户的 PATH 里, 非 root 敲命令会「找不到命令」,
# 而不是看到「需要 root 权限」这个有用的提示.
SELF_PATH="/usr/local/bin/tcpfit"
LEGACY_SELF="/usr/local/sbin/tcpfit.sh"   # v0.3.1 及更早装在这里, 装新版时清掉
# 面向用户的提示一律用这个, 不能用 $0 ——
# bash <(curl ...) 跑时 $0 是 /dev/fd/63, 提示出来的命令用户根本没法执行
# 提示用户"下一步敲什么". 装好之后 tcpfit 在 PATH 里, 直接说命令名即可；
# 没装成（非 root / 没 curl）才退回完整路径. 绝不能用 $0 ——
# bash <(curl ...) 跑时 $0 是 /dev/fd/63, 提示出来的命令用户根本没法执行.
disp(){
  [ -x "$SELF_PATH" ] && { echo "tcpfit"; return; }
  case "$0" in /dev/fd/*|/proc/self/fd/*|bash|-bash) echo "$SELF_PATH" ;; *) echo "$0" ;; esac
}
# 装到系统里的那一份, 必须和「你刚跑的这一份」是同一个版本.
#
# 原先无条件拉 main：你按 v0.3.0 下载、校验、运行, 它转头把 main 装进
# /usr/local/sbin —— 之后每次敲 tcpfit.sh 跑的都是没校验过的代码,
# 固定版本的意义被完全抵消. （我自己踩过：推完新版去远端验证, 看到的还是旧菜单.)
#
# 为什么不能直接复制"正在运行的脚本"：bash <(curl ...) 时 $0 是 /dev/fd/63,
# 内容已被 bash 读走, 再 cat 只能读到 0 字节；curl | bash 时 $0 = bash, 根本不可读.
# 实测验证过这两种情况. 所以只能按版本号回拉, 并校验拉到的确实是同一版.
SELF_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/v${VERSION}/tcpfit.sh"
self_install(){
  [ "$(id -u)" = 0 ] || return 0
  case "$0" in "$SELF_PATH") return 0 ;; esac      # 已经是装好的那份
  command -v curl >/dev/null || return 0
  curl -fsSL "$SELF_URL" -o "$SELF_PATH".tmp 2>/dev/null || return 0
  # 校验版本一致. 开发期 main 领先 tag 时这里会失败, 跳过安装也是对的.
  if [ -s "$SELF_PATH".tmp ] && head -1 "$SELF_PATH".tmp | grep -q '^#!' \
     && grep -q "^VERSION=\"$VERSION\"" "$SELF_PATH".tmp; then
    mv "$SELF_PATH".tmp "$SELF_PATH"; chmod +x "$SELF_PATH"
    rm -f "$LEGACY_SELF"                      # 清掉旧位置, 免得两份不同版本并存
    ok "Installed: run 'tcpfit' anytime"
  else
    rm -f "$SELF_PATH".tmp
  fi
}

# ── 从旧名字 nettune 迁移 ──────────────────────────────────────────────────
# 项目 v0.3.1 从 nettune 改名为 tcpfit. 老机器上所有产物的文件名都还是 nettune-*,
# 新脚本按新名字去找会一个都找不到 —— 最危险的是 take_snapshot 的保护：
# 它检查 $SYSCTL_FILE 是否存在, 改名后该变量指向新路径, 老文件在它眼里不存在,
# 于是把「已调优状态」当成出厂基线存进快照, rollback 从此永久错误且无任何报错.
# 所以必须先搬迁, 而不是假装老部署不存在.
migrate_legacy(){
  local old_state=/var/lib/nettune
  local old_sysctl=/etc/sysctl.d/99-nettune.conf
  local old_qdisc=/usr/local/sbin/nettune-qdisc.sh
  local old_unit=/etc/systemd/system/nettune-qdisc.service
  local old_hook=/etc/networkd-dispatcher/routable.d/50-nettune-initcwnd
  local old_mod=/etc/modules-load.d/nettune-bbr.conf
  local old_self=/usr/local/sbin/nettune.sh
  # 一个旧产物都没有 → 全新机器, 什么都不用做
  [ -e "$old_state" ] || [ -e "$old_sysctl" ] || [ -e "$old_unit" ] || return 0
  [ "$(id -u)" = 0 ] || return 0

  info "检测到旧版本(nettune)的部署, 正在迁移到新名字(tcpfit)…"
  local rate=""
  # 先把整形值抠出来, 后面用新名字重建；不能直接改文件名, unit 里的路径也要跟着变
  [ -f "$old_qdisc" ] && rate=$(grep -oE 'rate [0-9]+mbit' "$old_qdisc" | head -1 | grep -oE '[0-9]+')
  systemctl disable --now nettune-qdisc.service >/dev/null 2>&1
  rm -f "$old_unit" "$old_qdisc"; systemctl daemon-reload >/dev/null 2>&1

  # 逐文件搬, 不搬目录 —— mv -n 在目标目录已存在时会变成 STATE_DIR/nettune/,
  # 快照就找不到了; 而后面的 rm -rf 还可能把原数据删掉
  if [ -d "$old_state" ]; then
    mkdir -p "$STATE_DIR"
    for _f in "$old_state"/*; do
      [ -e "$_f" ] || continue
      [ -e "$STATE_DIR/$(basename "$_f")" ] || mv "$_f" "$STATE_DIR/"
    done
    rmdir "$old_state" 2>/dev/null || warn "旧目录 $old_state 非空, 已保留"
  fi
  [ -f "$old_sysctl" ] && mv -f "$old_sysctl" "$SYSCTL_FILE"
  [ -f "$old_hook" ]   && mv -f "$old_hook" "$ROUTE_HOOK"
  [ -f "$old_mod" ]    && mv -f "$old_mod" /etc/modules-load.d/tcpfit-bbr.conf
  rm -f "$old_self" "$LEGACY_SELF"

  if [ -n "$rate" ]; then
    write_qdisc "$rate" "$(detect_iface)"
    systemctl restart tcpfit-qdisc.service 2>/dev/null || "$QDISC_SCRIPT" >/dev/null 2>&1
    ok "迁移完成, 整形 ${rate}Mbit 已用新名字重建"
  else
    ok "迁移完成"
  fi
  info "快照保留在 $SNAPSHOT, rollback 仍然可用."
}

# ── 环境检测 ────────────────────────────────────────────────────────────────
# 默认路由网卡. 【不跟 $IP_FAMILY 走】—— 网卡是物理概念, 整形和 qdisc 打在同一张卡上,
# 选 v4 还是 v6 测速都是它. 只是纯 v6 机器的 v4 路由表是空的, 所以 v4 查不到时回退查 v6.
# (`ip route` 等价于 `ip -4 route`, 早期版本只写这一句, 纯 v6 机器直接
#  die "找不到默认路由网卡", 从来就没跑起来过.)
detect_iface(){
  local i
  i=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$i" ] || i=$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')
  echo "$i"
}
# 网关【只取 v4】. 它唯一的用途是 `ip route replace default via $gw ...`(设 initcwnd),
# 那是 IPv4 路由表操作, 喂 v6 地址进去会直接报
# "Error: inet address is expected rather than 2a0f:...". 实测验证过.
# 纯 v6 机器上这里返回空, 调用方的 [ -n "$gw" ] 会跳过 initcwnd —— 安全降级.
detect_gw(){    ip -4 route show default 2>/dev/null | awk '{print $3; exit}'; }

# 算 BDP 用的 RTT. 固定 150ms, 不再探测.  用 --rtt 可以覆盖.
#
# 为什么不测了 —— 旧做法是 ping 五个国内 DNS 取中位数, 三个问题让它没法用:
#
#  1. anycast 污染. 五个目标里腾讯/百度/CNNIC 三个是 anycast, 会命中就近节点.
#     本机(香港)实测: 2ms / 1ms / 1ms, 而真·国内是 138-145ms —— 中位数取出 2ms,
#     差 70 倍. 更糟的是 BDP 算小之后缓冲区落到 4MB 下限, 而 4MB 正好等于
#     Linux 出厂值, 等于"调了个寂寞", 还打印一份看着完全正常的推导过程.
#  2. 硬依赖 ping + ICMP. 精简镜像不带 iputils-ping, 有的机房挡 ICMP ——
#     两种情况都让 detect_rtt 返回空, 然后 die "无法确定 RTT, 请用 --rtt 指定",
#     而向导里根本没地方填这个参数, 报错把用户指向死路. 客户真踩过.
#  3. 就算测准了也没意义. "到中国的 RTT"不是一个数: 同一台机器同一时刻实测
#     移动 55ms / 联通 93ms / 电信 138ms / 上海电信 145ms, 差 2.6 倍,
#     再叠加晚高峰. 测出来的只是这个分布里随机的一个点.
#
# 为什么是 150 —— 缓冲区是 2×BDP, 所以估 E 能【全速覆盖到 2E】的目的地:
#     估 150 → 覆盖 ≤300ms. 大陆用户的全部场景都在里面:
#     优化线 40-70ms / 香港普通线 145ms / 美西 160-180ms / 欧美 230-250ms /
#     晚高峰拥塞 300ms —— 全部 100%.
# 再高没有收益: 200/300 多出来的覆盖(400/600ms)现实中用不上, 而且
#     小内存机器早被 RAM/32 封顶接住(512MB→16MB), 估多高结果都一样;
#     大机器上则要多付 BBR 超发的账 —— 实测超配 215 倍时掉 22% 吞吐.
# 估低才是真危险: 估 40 时只覆盖 80ms, 2G 口到美西只剩 941 Mbps(47%),
#     而且是硬天花板, 用户怎么测都上不去还查不出原因.
DEFAULT_RTT=150

detect_ram_mb(){ awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
detect_cores(){  nproc 2>/dev/null || echo 1; }

# 网卡标称速率. 虚拟网卡多半读不到, 返回空由调用方处理
detect_link_mbps(){
  local i="$1" s
  s=$(cat "/sys/class/net/$i/speed" 2>/dev/null)
  [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ] && echo "$s" || echo ""
}

cmd_detect(){
  local iface rtt ram cores link virt kern cc_avail queues
  iface=$(detect_iface); [ -n "$iface" ] || die "找不到默认路由网卡"
  rtt="$DEFAULT_RTT"; ram=$(detect_ram_mb); cores=$(detect_cores)
  link=$(detect_link_mbps "$iface")
  # systemd-detect-virt 在裸机上输出 none 但退出码为 1, 不能用 || 兜底
  virt=$(systemd-detect-virt 2>/dev/null); [ -n "$virt" ] || virt=unknown
  kern=$(uname -r)
  cc_avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
  queues=$(ls -d /sys/class/net/"$iface"/queues/rx-* 2>/dev/null | wc -l)

  echo "── Machine profile ──"
  kv "Interface"   "$iface"
  kv "Driver"      "$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver/{print $2}')"
  kv "RX queues"   "$queues"
  kv "Link speed"  "${link:-n/a (virtual NIC)}"
  kv "Kernel"      "$kern"
  kv "Virt"        "$virt"
  kv "CPU cores"   "$cores"
  kv "Memory MB"   "$ram"
  kv "RTT (assumed)" "${rtt}ms  — 固定值, 覆盖到 ${rtt}x2=$((rtt*2))ms 的路径; 要改用 tune --rtt"
  kv "CC available" "$cc_avail"
  kv "BBR"         "$(echo "$cc_avail" | grep -qw bbr && echo 是 || (modprobe tcp_bbr 2>/dev/null && echo '是(需加载模块)' || echo 否))"

  mkdir -p "$STATE_DIR"
  cat > "$FACTS" <<EOF
IFACE=$iface
RTT_MS=${rtt:-0}
RAM_MB=$ram
CORES=$cores
LINK_MBPS=${link:-0}
KERNEL=$kern
VIRT=$virt
EOF
}

# 数值参数校验. 所有会改系统的子命令都必须在动手之前调它 ——
# 早期版本 shape --rate abc 会先存快照、再让 tc 报错, 留下垃圾状态.
is_posint(){   # is_posint <值> <最小> <最大>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}

# ── 参数推导 ────────────────────────────────────────────────────────────────
# BDP(字节) = 带宽(Mbps) * 1e6 / 8 * RTT(s)
calc_bdp(){ awk -v b="$1" -v r="$2" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}'; }

# tcp_mem(页). 内核在 pressure 阈值就开始缩窗, max 是硬顶.
# 小内存机器上把 max 设成内存的一半是 OOM 主因 —— 这里固定按 1/8 与 1/4 推导.
calc_tcp_mem(){
  local ram_mb="$1"
  awk -v m="$ram_mb" 'BEGIN{
    pg=m*1024/4;                      # 总内存页数
    low=int(pg/16); pres=int(pg/8); max=int(pg/4);
    if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384;
    printf "%d %d %d", low, pres, max
  }'
}

# 缓冲区上限 = 2 × BDP, 但要受全局 TCP 预算约束.
#
# 原先是死写的 [4MB, 64MB]. 64MB 这个数在两头都错：
#   高带宽机被无谓截断 —— 2G/149ms 的机器 2×BDP 是 71MB, 被砍成 64MB,
#   接收窗口只剩 32MB, 单流上限 1.93Gbps, 刚好够不到 2G.
#   小内存机又太松 —— 1GB 的机器也允许单个 socket 占 64MB, 几条大流就吃光 tcp_mem.
#
# 改成跟 tcp_mem 挂钩：单个 socket 最多占全局 TCP 预算的 1/8, 即至少要能容下
# 8 条大流同时跑满. tcp_mem 上限本身是内存的 1/4, 所以这个值 ≈ 内存的 1/32.
# 绝对上限 256MB —— 再大就是单条连接垄断全局预算了, 收益也早已递减.
#
# 注意 rmem_max/wmem_max 是「天花板」不是预分配：开着 tcp_moderate_rcvbuf,
# 连接从 default 值起步, 只有真跑得快才长上去. 而 tcp_mem 是内核硬性拦截的总量,
# 所以调大这里不会把机器 OOM 掉, 最坏是 TCP 进入内存压力后缓冲区被自动缩小.
calc_buf_max(){   # calc_buf_max <BDP字节> <内存MB>
  awk -v b="$1" -v m="$2" 'BEGIN{
    v   = b*2
    cap = m*32768              # tcp_mem上限(内存1/4)的 1/8 = 内存/32, 单位字节
    if(cap > 268435456) cap = 268435456      # 绝对上限 256MB
    if(v > cap) v = cap
    if(v < 4194304) v = 4194304              # 下限 4MB, 低于此连百兆都跑不满
    printf "%d", v
  }'
}

# buf_max 是被哪个条件定住的 —— 输出里说明白, 否则用户看到一个被截断的值
# 却以为是 2×BDP, 会去怀疑别的地方（我自己就在 9300 那台上绕过弯路）.
buf_max_reason(){   # buf_max_reason <BDP字节> <内存MB> <算出的buf_max>
  awk -v b="$1" -v m="$2" -v v="$3" 'BEGIN{
    cap = m*32768; if(cap > 268435456) cap = 268435456
    if(v <= 4194304 && b*2 < 4194304) { print "floor 4MB"; exit }
    if(v >= cap && b*2 > cap)         { printf "capped by tcp_mem budget"; exit }
    print "2 x BDP"
  }'
}

# 整形安全余量：按标称带宽分 5 档给固定值.
# 不用百分比是因为百分比在两端都别扭 —— 100M 机器 3% 才 3Mbit 太小,
# 2G 机器 3% 就是 60Mbit 太浪费. 分档更贴合实际.
# 余量的意义：sweep 是在某个时刻测的, 晚高峰线路会变差, 留一点缓冲避免那时暴丢包.
calc_margin(){
  local bw="$1"
  if   [ "$bw" -le 100 ]  2>/dev/null; then echo 5      # ≤100M   小水管, 5 就够
  elif [ "$bw" -le 300 ]  2>/dev/null; then echo 10     # 101-300M
  elif [ "$bw" -le 600 ]  2>/dev/null; then echo 15     # 301-600M  最常见档位
  elif [ "$bw" -le 1000 ] 2>/dev/null; then echo 25     # 601-1000M
  else                                        echo 40   # >1G      大带宽波动也大
  fi
}

# 预估整个调优流程会跑掉多少流量. sweep 是大头 ——
# 档数随带宽线性增长, 每档还要按该速率跑满 12 秒, 千兆机器能跑掉几十 GB.
# 有流量配额的用户必须提前知道.
# 粗扫步长随带宽放大. 固定 20 时 2Gbps 机器要扫 40 档、跑掉 137GB ——
# 精度靠后面的细扫补, 粗扫没必要那么密.
calc_step(){ awk -v b="$1" 'BEGIN{s=int(b/30/10+0.5)*10; if(s<20)s=20; printf "%d", s}'; }

estimate_traffic_gb(){
  local st; st=$(calc_step "$1")
  awk -v b="$1" -v st="$st" 'BEGIN{
    steps = int(b*0.4/st) + 1            # 粗扫档数 = (1.2b-0.8b)/步长
    mb  = b*10/8                         # probe   4 流 10 秒
    mb += b*0.4                          # 路径验证 40% 速率 8 秒
    mb += (steps+3) * b*12/8             # 粗扫 + 细扫 3 档, 每档 12 秒
    mb += b*10/8*2                       # verify 单流 + 4 流各 10 秒
    printf "%.1f", mb/1024
  }'
}

# 缓冲区默认值（起点）决定爬坡快慢, 但每 socket 都吃这么多额度.
#   proxy 角色并发上百条连接 → 保守, 1MB
#   bulk  角色只有少数大流   → 激进, 可到 BDP
calc_buf_default(){
  local role="$1" bdp="$2"
  case "$role" in
    proxy) echo 1048576 ;;
    bulk)  awk -v b="$bdp" 'BEGIN{v=b; if(v<1048576)v=1048576; if(v>8388608)v=8388608; printf "%d", v}' ;;
    *)     echo 2097152 ;;
  esac
}

# 调优会动到的全部内核参数. 快照和回滚都以这份清单为准 ——
# 早期版本快照只记了 14 项而 tune 设了 31 项, 回滚后有 17 项在重启前仍是调优值.
# 加参数时必须同时加到这里, 否则那个参数就回滚不掉.
TUNED_KEYS="
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.core.rmem_max
  net.core.wmem_max
  net.core.rmem_default
  net.core.wmem_default
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.ipv4.tcp_mem
  net.ipv4.tcp_window_scaling
  net.ipv4.tcp_moderate_rcvbuf
  net.ipv4.tcp_adv_win_scale
  net.core.netdev_max_backlog
  net.core.netdev_budget
  net.core.netdev_budget_usecs
  net.core.optmem_max
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_slow_start_after_idle
  net.ipv4.tcp_no_metrics_save
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_sack
  net.ipv4.tcp_dsack
  net.ipv4.tcp_timestamps
  net.ipv4.tcp_fastopen
  net.ipv4.tcp_syncookies
  net.ipv4.tcp_tw_reuse
  net.ipv4.tcp_fin_timeout
  net.ipv4.tcp_keepalive_time
  net.ipv4.ip_local_port_range
  vm.min_free_kbytes
  fs.file-max
  vm.swappiness
"

# ── 快照与回滚 ──────────────────────────────────────────────────────────────
take_snapshot(){
  mkdir -p "$STATE_DIR"
  [ -f "$SNAPSHOT" ] && { info "Snapshot already exists, keeping the earliest one"; return; }
  # 机器已经被调过（手工或旧版本）却没有快照时, 当前状态不能当基线 ——
  # 那样 rollback 只会回到"调优后", 永远回不到出厂. 必须让用户先明确基线.
  if [ -f "$SYSCTL_FILE" ] || [ -f "$QDISC_SCRIPT" ]; then
    warn "检测到本机已有调优配置, 但没有出厂快照."
    warn "现在存快照会把「已调优状态」误记成基线, 导致 rollback 失效."
    warn "请先二选一："
    warn "  a) 手工写好出厂值到 $SNAPSHOT（格式见 docs）"
    warn "  b) 先 $(disp) rollback 回到出厂, 再重新 tune"
    warn "  c) 确认无需回滚能力, 则: touch $SNAPSHOT"
    die "已中止, 未做任何改动" 1
  fi
  local iface; iface=$(detect_iface)
  {
    echo "# tcpfit pre-tune snapshot  $(date -u +%FT%TZ)"
    echo "KERNEL=$(uname -r)"
    for k in $TUNED_KEYS; do
      printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
    done
    echo "# route: $(ip route show default)"
    echo "# qdisc: $(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
  } > "$SNAPSHOT"
  ok "Snapshot saved: $SNAPSHOT"
}

cmd_rollback(){
  need_root
  take_lock
  migrate_legacy
  local purge_swap=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge-swap) purge_swap=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  info "回滚中…"
  rm -f "$SYSCTL_FILE" "$ROUTE_HOOK" /etc/modules-load.d/tcpfit-bbr.conf
  systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
  rm -f "$QDISC_UNIT" "$QDISC_SCRIPT"
  systemctl daemon-reload >/dev/null 2>&1
  local iface; iface=$(detect_iface)
  tc qdisc del dev "$iface" root 2>/dev/null
  local gw; gw=$(detect_gw)
  [ -n "$gw" ] && ip route replace default via "$gw" dev "$iface" 2>/dev/null
  # 逐项写回快照值
  if [ -f "$SNAPSHOT" ]; then
    grep -E '^(net|vm|fs)\.' "$SNAPSHOT" | while IFS='=' read -r k v; do
      k=$(echo "$k" | xargs); v=$(echo "$v" | xargs)
      [ -n "$k" ] && [ -n "$v" ] && sysctl -qw "$k=$v" 2>/dev/null
    done
    ok "已按快照还原 sysctl"
  else
    warn "找不到快照, 仅移除了调优文件；重启后内核默认值生效"
  fi
  # swap 默认不动 —— 删掉一个正在用的 swap 可能让机器立刻 OOM.
  # 想连 swap 一起撤销要显式加 --purge-swap.
  if [ "$purge_swap" = 1 ]; then
    if [ ! -f /swapfile ]; then
      info "没有 /swapfile, 跳过"
    elif [ ! -f "$STATE_DIR/swapfile.owned" ]; then
      warn "/swapfile 不是 tcpfit 创建的, 拒绝删除. 要删请自己确认后手动操作"
    elif ! swapoff /swapfile 2>/dev/null; then
      # swapoff 失败通常是内存不够把页换回来, 这时删文件会让内核继续写一个
      # 已删除的 inode, 空间也不会释放 —— 必须停手
      warn "swapoff /swapfile 失败（内存可能不足以换回), 未删除. 释放内存后重试"
    else
      rm -f /swapfile
      sed -i '\#^/swapfile #d' /etc/fstab
      rm -f "$STATE_DIR/swapfile.owned"
      ok "已移除 /swapfile 及其 fstab 条目"
    fi
  elif [ -f /swapfile ]; then
    info "/swapfile 保留. 要一并删除: $(disp) rollback --purge-swap"
  fi
  ok "回滚完成"
}

# ── 基础调优 ────────────────────────────────────────────────────────────────
cmd_tune(){
  need_root
  take_lock
  migrate_legacy
  self_install
  local role=mixed bw="" rtt="" no_initcwnd=0 peer=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="$2"; shift 2 ;;
      --bw)   bw="$2";   shift 2 ;;
      --rtt)  rtt="$2";  shift 2 ;;
      --peer) peer="$2"; shift 2 ;;
      --no-initcwnd) no_initcwnd=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  case "$role" in proxy|bulk|mixed) ;; *) die "role 只能是 proxy / bulk / mixed" ;; esac

  local iface ram; iface=$(detect_iface); ram=$(detect_ram_mb)
  [ -n "$iface" ] || die "找不到默认路由网卡"
  # --rtt 给了就用给的, 没给就用固定值. 不再探测, 所以不会再出现
  # "无法确定 RTT" 这种把用户指向死路的报错（向导里根本没地方填 --rtt）.
  if [ -n "$rtt" ]; then
    is_posint "$rtt" 1 2000 || die "--rtt 必须是 1-2000 之间的整数（毫秒）"
  else
    rtt="$DEFAULT_RTT"
  fi
  # --bw auto: 现场探测. 虚拟网卡读不到标称速率, 这是最常见的情况.
  if [ "$bw" = auto ]; then
    [ -n "$peer" ] || die "--bw auto 需要同时给 --peer <近处的iperf3服务器>"
    command -v iperf3 >/dev/null || die "--bw auto 需要 iperf3"
    info "Probing available bandwidth..."
    bw=$(probe_bandwidth "$peer" "$iface") || bw=""
    [ -n "$bw" ] && ok "Measured ~${bw} Mbps" || die "bandwidth probe failed" 2
  fi
  [ -n "$bw" ] || bw=$(detect_link_mbps "$iface")
  if ! { [ -n "$bw" ] && [ "$bw" -gt 0 ] 2>/dev/null; }; then
    warn "本机是虚拟网卡, 读不到标称速率. 三选一："
    warn "  a) 知道套餐带宽:  $(disp) tune --role $role --bw <Mbps>"
    warn "  b) 现场探测:      $(disp) tune --role $role --bw auto --peer <近处iperf3服务器>"
    warn "  c) 先单独探测:    $(disp) probe --peer <近处iperf3服务器>"
    die "无法确定带宽, 已中止" 1
  fi

  take_snapshot

  local bdp buf_max buf_def tcp_mem
  bdp=$(calc_bdp "$bw" "$rtt")
  buf_max=$(calc_buf_max "$bdp" "$ram")
  buf_def=$(calc_buf_default "$role" "$bdp")
  tcp_mem=$(calc_tcp_mem "$ram")

  info "Derived from: ${bw} Mbps / RTT ${rtt} ms / ${ram} MB RAM / role $role"
  kv "  BDP"            "$(awk -v v="$bdp" 'BEGIN{printf "%.1f MB", v/1048576}')"
  kv "  Buffer max"     "$(awk -v v="$buf_max" 'BEGIN{printf "%.0f MB", v/1048576}')  ($(buf_max_reason "$bdp" "$ram" "$buf_max"))"
  kv "  Buffer default" "$(awk -v v="$buf_def" 'BEGIN{printf "%.0f MB", v/1048576}')  (role $role)"
  kv "  tcp_mem"        "$(echo "$tcp_mem" | awk '{printf "%.0fM / %.0fM / %.0fM", $1*4/1024, $2*4/1024, $3*4/1024}')  (RAM 1/16, 1/8, 1/4)"

  modprobe tcp_bbr 2>/dev/null
  echo tcp_bbr > /etc/modules-load.d/tcpfit-bbr.conf
  local cc=bbr
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || {
    warn "kernel has no BBR, falling back to cubic (much smaller gain)"; cc=cubic; }

  cat > "$SYSCTL_FILE" <<EOF
# 由 tcpfit v$VERSION 生成  $(date -u +%FT%TZ)
# 带宽=${bw}Mbps  RTT=${rtt}ms  内存=${ram}MB  角色=${role}
# 勿手改；要改用 tcpfit tune 重新生成

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc

# 缓冲区：上限=2×BDP, 默认值按角色（默认值决定爬坡快慢, 也决定每连接内存占用）
net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.core.rmem_default = $buf_def
net.core.wmem_default = $buf_def
net.ipv4.tcp_rmem = 4096 $buf_def $buf_max
net.ipv4.tcp_wmem = 4096 $buf_def $buf_max
# 全局 TCP 内存上限, 按物理内存推导. 设太高是小内存机 OOM 的主因.
net.ipv4.tcp_mem = $tcp_mem

net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1

net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
net.core.optmem_max = 65536
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535

vm.min_free_kbytes = 32768
fs.file-max = 1000000

# 刻意不设的项:
#   tcp_notsent_lowat  —— 低核数机器上压吞吐
#   tcp_reordering=300 —— 现代内核走 RACK, 调高只推迟快速重传
EOF

  # 不吞错误: 内核不支持某个参数时要让用户看见, 而不是照样报"applied"
  local serr; serr=$(sysctl -qp "$SYSCTL_FILE" 2>&1 >/dev/null)
  if [ -n "$serr" ]; then
    # 个别参数被内核拒绝很常见(不同内核版本支持的项不一样), 不是整体失败.
    # 用户看到 warning 容易以为调优挂了, 措辞要说清楚.
    warn "以下参数当前内核不支持, 已跳过, 不影响其他调优:"
    echo "$serr" | sed 's/^/      /' >&2
    ok "sysctl applied: $SYSCTL_FILE"
  else
    ok "sysctl applied: $SYSCTL_FILE"
  fi

  if [ "$no_initcwnd" = 0 ]; then
    local gw; gw=$(detect_gw)
    if [ -n "$gw" ]; then
      ip route replace default via "$gw" dev "$iface" initcwnd 32 initrwnd 32 2>/dev/null \
        && ok "initcwnd/initrwnd = 32" || warn "initcwnd not applied (unsupported on some hypervisors)"
      if [ -d /etc/networkd-dispatcher/routable.d ]; then
        cat > "$ROUTE_HOOK" <<'H'
#!/bin/bash
GW=$(ip route show default | awk '{print $3; exit}')
IF=$(ip route show default | awk '{print $5; exit}')
[ -n "$GW" ] && [ -n "$IF" ] && ip route replace default via "$GW" dev "$IF" initcwnd 32 initrwnd 32
exit 0
H
        chmod +x "$ROUTE_HOOK"
      fi
    fi
  fi

  # 一键流程里这些收尾由 wizard 统一打印, 避免中英文交错
  [ "$WIZARD" = 1 ] && return 0

  info "基础调优完成. 下一步跑 sweep 找限速器拐点 —— 那才是大头."
  echo "  $(disp) sweep --peer <近处的iperf3服务器> --nominal $bw"

  # 小内存机不加 swap 就是定时炸弹：实测过 tcp_mem 撑爆内存把代理进程连杀 7 次
  if [ "$ram" -le 1024 ] && ! swapon --show 2>/dev/null | grep -q .; then
    echo
    warn "本机内存 ${ram}MB 且无 swap, 跑代理建议加一个：$(disp) harden --swap 2G"
  fi
}

# ── 系统加固 ────────────────────────────────────────────────────────────────
# 与网络参数无关, 但小内存机不加 swap 就没有任何缓冲余地：TCP 缓冲区一涨,
# 内核直接杀进程. 表现是"测速跑一半掉速", 要翻 journalctl 才看得出来.
cmd_harden(){
  need_root
  take_lock
  local swap_size=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --swap) swap_size="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [ -n "$swap_size" ] || die "需要 --swap <大小>, 例如 --swap 2G 或 --swap 2"

  # 单位一律按 GB. "2" 和 "2G" 都收 —— 向导和文档里写的都是 2G, 只收纯数字
  # 会把它们全挡掉（v0.4.3 就是这样, 向导结尾的 swap 提示按 y 之后直接 die 退出）.
  # 但不收 "2M": fallocate 会建 2MB, 而失败回退的 dd 建 2GB, 两条路差 1000 倍.
  local gb="${swap_size%[Gg]}"
  is_posint "$gb" 1 20 || die "swap 大小请填 1-20 之间的整数, 单位 GB（例如 2 或 2G）"
  swap_size="${gb}G"

  # 校验通过再存快照, 打错参数不该留下状态
  take_snapshot        # harden 会往 $SYSCTL_FILE 追加 vm.swappiness,
                       # 不存快照的话之后跑 tune 会因"有配置无快照"直接中止

  if swapon --show 2>/dev/null | grep -q .; then
    info "已有 swap, 跳过: $(free -h | awk '/Swap/{print $2}')"
    return 0
  fi
  # 已存在但没启用的 /swapfile 不能盖 —— 那可能是用户自己准备的
  [ -e /swapfile ] && die "/swapfile 已存在但未启用. 先确认它的用途, 需要的话手动删除后再跑"
  info "创建 ${swap_size} swap…"
  fallocate -l "$swap_size" /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count=$(( gb * 1024 )) status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile \
    || die "swap 创建失败"
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  # 记下这个 swapfile 是 tcpfit 建的; --purge-swap 只删有这个标记的
  mkdir -p "$STATE_DIR"; : > "$STATE_DIR/swapfile.owned"
  ok "swap 已启用: $(free -h | awk '/Swap/{print $2}')"
  # 只在内存真的紧张时才用 swap, 避免平时把热数据换出去拖慢代理
  sysctl -qw vm.swappiness=10
  grep -q '^vm.swappiness' "$SYSCTL_FILE" 2>/dev/null || echo "vm.swappiness = 10" >> "$SYSCTL_FILE"
  ok "vm.swappiness = 10"
}

# ── 出向整形 ────────────────────────────────────────────────────────────────
# HTB 做全局上限（多流场景必需）, fq 叶子做 hrtimer 逐包 pacing.
# burst 压到 32k：HTB 默认 burst 按 rate/HZ 算, 会放行微突发打穿限速器.
write_qdisc(){
  local rate="$1" iface="$2"
  cat > "$QDISC_SCRIPT" <<EOF
#!/bin/bash
IF=${iface}
RATE=\${1:-${rate}}
tc qdisc del dev \$IF root 2>/dev/null
tc qdisc add dev \$IF root handle 1: htb default 10
tc class add dev \$IF parent 1: classid 1:10 htb rate \${RATE}mbit ceil \${RATE}mbit burst 32k cburst 32k quantum 1514
tc qdisc add dev \$IF parent 1:10 handle 10: fq limit 40960 flow_limit 8192 maxrate \${RATE}mbit
EOF
  chmod +x "$QDISC_SCRIPT"
  cat > "$QDISC_UNIT" <<EOF
[Unit]
Description=tcpfit egress shaper
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$QDISC_SCRIPT $rate
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  # 用 --now 而不是只 enable：否则 tc 规则虽已生效, systemctl is-active 却显示
  # inactive, status 里看着像坏了. 让 unit 状态和实际状态一致.
  systemctl enable --now tcpfit-qdisc.service >/dev/null 2>&1
}

cmd_shape(){
  need_root
  take_lock
  local rate="" off=0 iface
  while [ $# -gt 0 ]; do
    case "$1" in
      --rate) rate="$2"; shift 2 ;;
      --off)  off=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  iface=$(detect_iface)

  # 没有限速器可躲的机器（sweep 全程干净）, HTB 的硬上限只会限制自己 ——
  # 而且 HTB 实际投递只有标称的 93-96%, 设 2Gbit 就永远摸不到 2Gbit.
  # 移除后根 qdisc 退回纯 fq：BBR 的逐 socket pacing 仍然生效, 只是没有聚合上限.
  # 注意不动 sysctl, 基础调优完整保留 —— 这是它和 rollback 的区别.
  if [ "$off" = 1 ]; then
    systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
    rm -f "$QDISC_UNIT" "$QDISC_SCRIPT"
    systemctl daemon-reload >/dev/null 2>&1
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root fq 2>/dev/null
    ok "整形已移除, qdisc 恢复为纯 fq"
    info "BBR 的逐 socket pacing 仍然生效, 只是没有了聚合速率上限."
    info "基础调优（拥塞控制 / 缓冲区）未受影响."
    [ "$WIZARD" = 1 ] || tc qdisc show dev "$iface" | head -1
    return 0
  fi

  [ -n "$rate" ] || die "需要 --rate <Mbit>, 或用 --off 移除整形"
  # 校验必须在 take_snapshot 之前 —— 否则打错一个字就会留下快照和半截 qdisc
  is_posint "$rate" 1 100000 || die "--rate 必须是 1-100000 的整数（Mbit）"
  take_snapshot
  write_qdisc "$rate" "$iface"
  systemctl restart tcpfit-qdisc.service 2>/dev/null || "$QDISC_SCRIPT" "$rate"
  # 事后用 tc 核对, 不能只看命令有没有报错
  if tc class show dev "$iface" 2>/dev/null | grep -q "rate ${rate}Mbit"; then
    ok "HTB ${rate} Mbit + fq leaf pacing on ${iface}"
  else
    warn "shaping did not take effect on ${iface} -- check: tc qdisc show dev ${iface}"
    return 1
  fi
  systemctl is-enabled tcpfit-qdisc.service >/dev/null 2>&1 \
    && ok "tcpfit-qdisc.service enabled (survives reboot)" \
    || warn "tcpfit-qdisc.service not enabled -- shaping will be lost on reboot"
  [ "$WIZARD" = 1 ] || tc class show dev "$iface"
}

# 测试期间的临时整形. 结构必须和 write_qdisc 生成的完全一致.
#
# 两个原因:
#   1) fq 的 maxrate 是【每条流】的上限, 不是聚合上限. 实测: fq maxrate 300mbit
#      跑 -P 1 得 283 Mbps, 跑 -P 4 得 1134 Mbps(约 4 倍). 只有 HTB 才是聚合限速.
#      早期版本用 fq maxrate 做限速, 于是 validate_peer(跑 -P 2)名义上限 40%
#      实际能冲到 80%, 可能撞上限速器再把丢包报成"链路本身有损".
#   2) 扫描用一种结构、最终应用另一种结构的话, 测出来的拐点对不上实际部署.
apply_test_shaper(){   # apply_test_shaper <iface> <rate_mbit>
  local iface="$1" rate="$2"
  tc qdisc del dev "$iface" root 2>/dev/null
  tc qdisc add dev "$iface" root handle 1: htb default 10 2>/dev/null || return 1
  tc class add dev "$iface" parent 1: classid 1:10 htb \
     rate "${rate}mbit" ceil "${rate}mbit" burst 32k cburst 32k quantum 1514 2>/dev/null || return 1
  tc qdisc add dev "$iface" parent 1:10 handle 10: fq \
     limit 40960 flow_limit 8192 maxrate "${rate}mbit" 2>/dev/null || return 1
}

# ── 测试用 qdisc 的保存与恢复 ────────────────────────────────────────────────
# probe / validate_peer / sweep 都要临时换掉根 qdisc. 早期版本恢复时一律装成 fq,
# 于是原来的 mq(多队列网卡的正常结构)、CAKE 等配置被永久吞掉且无提示.
# 现在完整记下原始根 qdisc, 结束时按原样恢复.
QSAVE_KIND=""; QSAVE_IFACE=""
qdisc_save(){   # qdisc_save <iface>
  QSAVE_IFACE="$1"
  QSAVE_KIND=$(tc qdisc show dev "$1" 2>/dev/null | awk '$1=="qdisc"{print $2; exit}')
}
# 把本脚本起的 iperf3 全部收掉. 只杀自己的子进程, 不动用户手工跑的.
# BusyBox(Alpine) 的 timeout 没有 --foreground, pkill 没有 -g. 启动时探一次,
# 不支持就退回到能用的写法, 而不是让每次调用都报错.
TIMEOUT_FG=""
timeout --foreground 1 true >/dev/null 2>&1 && TIMEOUT_FG="--foreground"
# 不能靠"跑一次看退出码"判断: BusyBox 不认 -g 时也返回 1, 会被误判成支持.
# 改看帮助里有没有长选项 --pgroup —— BusyBox 压根不支持长选项.
PKILL_G=0
pkill --help 2>&1 | grep -q -- '--pgroup' && PKILL_G=1

# 收掉本脚本起的 iperf3. 优先按进程组匹配 —— iperf3 的父进程是 timeout 不是本脚本,
# 按 -P $$ 匹配不到. 只杀同组的, 不动用户手工跑的.
reap_iperf(){
  if [ "$PKILL_G" = 1 ]; then
    pkill -g $$ -x iperf3 2>/dev/null; pkill -g $$ -x timeout 2>/dev/null
  else
    pkill -P $$ -x iperf3 2>/dev/null; pkill -P $$ -x timeout 2>/dev/null
  fi
  return 0
}

qdisc_restore(){
  reap_iperf
  [ -n "$QSAVE_IFACE" ] || return 0
  tc qdisc del dev "$QSAVE_IFACE" root 2>/dev/null
  if [ -x "$QDISC_SCRIPT" ]; then
    "$QDISC_SCRIPT" >/dev/null 2>&1 && { QSAVE_IFACE=""; return 0; }
  fi
  case "$QSAVE_KIND" in
    # mq 是内核按硬件队列自动建的, 删掉 root 后它会自己回来, 不能手工 add
    ""|mq|noqueue|pfifo_fast) : ;;
    *) tc qdisc add dev "$QSAVE_IFACE" root "$QSAVE_KIND" 2>/dev/null ;;
  esac
  QSAVE_IFACE=""
}
# 未知/自定义 qdisc 不是我们能原样重建的, 先问过用户
qdisc_guard(){   # qdisc_guard <iface>
  local k; k=$(tc qdisc show dev "$1" 2>/dev/null | awk '$1=="qdisc"{print $2; exit}')
  case "$k" in
    ""|mq|fq|noqueue|pfifo_fast|fq_codel|htb) return 0 ;;
  esac
  warn "本机根 qdisc 是 ${k}, 测试期间会被临时替换."
  warn "结束时只能恢复成 ${k} 的默认参数, 自己的调优配置会丢失."
  confirm "  继续？" || return 1
}

# ── 带宽探测 ────────────────────────────────────────────────────────────────
# 虚拟网卡读不到标称速率(/sys/class/net/*/speed 为 -1), 而用户未必记得买的是多少兆.
# 这里用带 pacing 的多流测试估一个可用带宽, 供 tune 推导 BDP.
# 注意：这只是"够用的估计", 真正的限速器拐点仍要靠 sweep 实测.
probe_bandwidth(){
  local peer="$1" iface="$2" dur="${3:-10}"
  qdisc_save "$iface"
  trap 'qdisc_restore; exit 130' INT TERM HUP
  # 用 fq 做 pacing 但不设上限: 既避免突发打穿限速器, 又能探到真实上限
  tc qdisc del dev "$iface" root 2>/dev/null
  tc qdisc add dev "$iface" root fq 2>/dev/null
  local res gp
  for a in 1 2 3; do res=$(run_iperf "$peer" "$dur" 4); [ -n "$res" ] && break; sleep 8; done
  trap - INT TERM HUP
  qdisc_restore
  [ -n "$res" ] || { echo ""; return 1; }
  gp=$(echo "$res" | awk '{print $1}')
  # 取最近的 50Mbps 档. 早期版本无脑向上取整, 实测把 305Mbps 估成 350,
  # 导致 sweep 的扫描区间整体偏高.
  awk -v g="$gp" 'BEGIN{printf "%d", int(g/50+0.5)*50}'
}

cmd_probe(){
  need_root
  take_lock
  command -v iperf3 >/dev/null || die "需要 iperf3"
  local peer=""
  while [ $# -gt 0 ]; do
    case "$1" in --peer) peer="$2"; shift 2 ;; *) die "未知参数: $1" ;; esac
  done
  [ -n "$peer" ] || die "需要 --peer <近处的iperf3服务器>"
  local iface; iface=$(detect_iface)
  qdisc_guard "$iface" || { info "已取消"; return 0; }
  info "探测可用带宽（4 并发 + pacing, 约 15 秒）…"
  local bw; bw=$(probe_bandwidth "$peer" "$iface")
  [ -n "$bw" ] || die "探测失败, 检查对端 $peer 是否可达/空闲" 2
  mkdir -p "$STATE_DIR"; echo "BW_MBPS=$bw" > "$STATE_DIR/probe.result"
  ok "估计可用带宽 ≈ ${bw} Mbps"
  echo
  echo "  这只是给 tune 算 BDP 用的估计值, 真正的限速器拐点靠 sweep 实测."
  echo "  下一步: $0 tune --role <proxy|bulk|mixed> --bw $bw"
}

# ── 限速器拐点扫描 ──────────────────────────────────────────────────────────
# 原理: 端口上的限速器(policer)看的是瞬时速率. 不加 pacing 的 TCP 发送是突发的,
# 平均速率没超也会被打穿. 加 fq pacing 后可以贴着真实上限跑而几乎不丢包.
# 拐点 = 重传开始跳变的那一档；取前一档再退安全余量.
# NETTUNE_VERBOSE=1 时把 iperf3 原始输出打到 stderr, 让用户看到测速在跑
# $1=peer $2=dur $3=parallel [$4=port]  -> "goodput retrans"
# 公共节点各开十个实例（Leaseweb/OVH 5201-5210, Clouvider 5200-5209）,
# 指定端口忙时自动换 —— 否则单端口一忙就整个失败. 端口表见 PORT_POOL.
run_iperf(){
  local out raw tmp port ports pid first="${4:-${PEER_PORT:-5201}}"
  ports=$(port_order "$first")
  tmp=$(mktemp)
  for port in $ports; do
    : > "$tmp"
    timeout $TIMEOUT_FG $(( $2 + 25 )) iperf3 $IP_FAMILY -c "$1" -p "$port" -t "$2" -P "$3" -f m >"$tmp" 2>&1 &
    pid=$!
    # --foreground 是必须的: timeout 默认把子进程放进【独立进程组】(方便超时时杀整组),
    # 结果 Ctrl-C 发给脚本进程组的 SIGINT 根本到不了 iperf3, 它会继续满速跑到
    # timeout 到期 —— 9Gbps 的机器上那是十几 GB 白烧. 实测验证过:
    #   默认        iperf3 进程组 ≠ 脚本组, Ctrl-C 后残留 1 个
    #   --foreground 两者相同,        Ctrl-C 后残留 0 个
    # 下面的 trap 是第二道保险, 走 kill 路径时用.
    trap 'kill -TERM "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; rm -f "$tmp"; exit 130' INT TERM HUP
    spin_wait "$pid" "测速中… ${2}s × ${3} 流  →  $1:$port"
    trap - INT TERM HUP
    # 判据是"有没有拿到有效结果", 不是枚举报错文案 —— iperf3 在服务端忙的时候
    # 会随机吐两种错, 早期只认 "busy running a test", 碰上
    # "unable to send control message: Connection reset by peer" 就直接放弃换端口了.
    grep -qE "$( [ "$3" -gt 1 ] && echo 'SUM.*sender' || echo 'sender' )" "$tmp" 2>/dev/null && break
  done
  raw=$(cat "$tmp"); rm -f "$tmp"
  [ "${NETTUNE_VERBOSE:-0}" = 1 ] && echo "$raw" | sed 's/^/      | /' >&2
  out=$(echo "$raw" | grep -E "$( [ "$3" -gt 1 ] && echo 'SUM.*sender' || echo 'sender' )" | tail -1)
  [ -z "$out" ] && { echo ""; return; }
  echo "$out" | awk '{print $(NF-3), $(NF-1)}'
}

# 丢包率(%) = 重传数 / 发出的包数. 包数按 1448 字节 MSS 估算.
#
# 为什么不能用绝对次数：阈值 100 在 300M 机上相当于 0.032% 丢包,
# 在 7.4G 机上只有 0.0014% —— 严了 25 倍. 实测踩过：一台 10G 口的机器
# 第一档 7440Mbit 实测 7001Mbps、重传 101（丢包率 0.0014%, 链路干净得离谱）,
# 却被判成撞了限速器, LAST_OK 为空直接报 "no usable rate measured" 退出,
# 整个扫描一档都没跑成.
#
# 七组真实数据回归：干净侧最高 0.0017%, 撞限速器最低 1.3541%.
# 阈值取 0.1%, 距两侧分别有 59 倍和 13.5 倍余量, 且自动适配任何带宽.
loss_pct(){   # loss_pct <重传数> <吞吐Mbps> <秒数>
  awk -v rt="$1" -v gp="$2" -v d="$3" 'BEGIN{
    pk = gp*1000000*d/8/1448          # 发出的包数
    if(pk < 1) pk = 1
    printf "%.4f", rt*100/pk
  }'
}

cmd_sweep(){
  need_root
  take_lock
  command -v iperf3 >/dev/null || die "需要 iperf3: apt install -y iperf3 / yum install -y iperf3"
  # GAP: 档与档之间的静置时间, 让上一条流的状态排空, 避免相邻两档互相干扰
  local peer="" nominal="" lo="" hi="" step="" dur=12 par=1 margin="" thresh=0.1 refine=1 GAP=3 cap=2500
  while [ $# -gt 0 ]; do
    case "$1" in
      --peer) peer="$2"; shift 2 ;;
      --port) PEER_PORT="$2"; shift 2 ;;
      -4) IP_FAMILY="-4"; shift ;;
      -6) IP_FAMILY="-6"; shift ;;
      --nominal) nominal="$2"; shift 2 ;;
      --from) lo="$2"; shift 2 ;;
      --to) hi="$2"; shift 2 ;;
      --step) step="$2"; shift 2 ;;
      --dur) dur="$2"; shift 2 ;;
      --parallel) par="$2"; shift 2 ;;
      --margin) margin="$2"; shift 2 ;;
      --gap) GAP="$2"; shift 2 ;;
      --cap) cap="$2"; shift 2 ;;
      --no-refine) refine=0; shift ;;
      --loss-threshold|--retrans-threshold) thresh="$2"; shift 2 ;;   # 单位是百分比
      *) die "未知参数: $1" ;;
    esac
  done
  for _v in "nominal:$nominal:1:1000000" "step:$step:1:100000" "dur:$dur:1:600" \
            "par:$par:1:128" "lo:$lo:1:1000000" "hi:$hi:1:1000000" "gap:$GAP:0:60"; do
    _n=${_v%%:*}; _r=${_v#*:}; _val=${_r%%:*}; _r=${_r#*:}; _min=${_r%%:*}; _max=${_r#*:}
    [ -z "$_val" ] && continue
    is_posint "$_val" "$_min" "$_max" || die "--${_n} 必须是 ${_min}-${_max} 的整数"
  done
  [ -n "$peer" ] || die "需要 --peer <iperf3服务器>, 选延迟低的, 测的是本机端口上限而非跨国链路"
  local iface; iface=$(detect_iface)
  # 手工给了区间就完全按用户说的来, 不做不限速探测
  local user_range=""; [ -n "$lo" ] && [ -n "$hi" ] && user_range=1
  # 手工给了区间: 缺的标称值用区间上界顶上. 自动模式下 nominal/lo/hi/step
  # 全部由后面的不限速探测决定, 这里不需要它们.
  if [ -n "$user_range" ]; then
    [ -n "$nominal" ] || nominal="$hi"
    [ -n "$step" ] || step=$(calc_step "$nominal")
  fi
  is_posint "$cap" 100 100000 || die "--cap 必须是 100-100000 的整数"
  # 校验一过就清掉上一轮的结果, 必须在任何 return 之前 ——
  # 否则这轮失败(对端太慢/探测失败/取消)时, 向导和菜单会读到上次的 RECOMMEND
  # 并把旧限速值应用上去, 而屏幕上写的是 "shaping skipped".
  mkdir -p "$STATE_DIR"; rm -f "$STATE_DIR/sweep.result"
  qdisc_guard "$iface" || { info "已取消"; return 0; }

  [ "$WIZARD" = 1 ] || traffic_mark
  info "Peer ${peer}:${PEER_PORT}"

  # 扫描会反复替换 qdisc；无论正常结束、拐点 break 还是被 Ctrl-C,
  # 都必须把机器恢复原状 —— 否则会被留在那个暴丢包的档位上.
  qdisc_save "$iface"
  restore_qdisc(){ qdisc_restore; info "qdisc restored"; }
  trap 'echo; warn "interrupted, restoring qdisc..."; qdisc_restore; exit 130' INT TERM HUP   # 中断退出是对的

  # 扫一段区间. 结果放进全局 LAST_OK(最后一个干净档) 与 BROKE_AT(重传跳变的那档)
  LAST_OK=""; BROKE_AT=""; SLOW_HITS=0; PEER_TOO_SLOW=0; BASE_LOSS=""
  # 跳变判定: 既要超过绝对阈值, 也要明显高于本底. 两个条件都满足才算.
  is_spike(){
    awk -v l="$1" -v t="$thresh" -v b="${BASE_LOSS:-0}" 'BEGIN{
      if (l <= t) exit 1
      if (b > 0 && l < b*10) exit 1
      exit 0
    }' 2>/dev/null
  }
  scan_range(){
    local a b st r res gp rt lp prev_gp=0 verdict
    a=$1; b=$2; st=$3
    # 终点必测: 168→221 步长 20 只会测 168/188/208, 而提示里写的是"扫到 221",
    # 上界从来没被验证过. 补一档把终点带上.
    local pts="" _r
    for (( _r=a; _r<=b; _r+=st )); do pts="$pts $_r"; done
    case " $pts " in *" $b "*) ;; *) pts="$pts $b" ;; esac
    for r in $pts; do
      apply_test_shaper "$iface" "$r" || { warn "failed to apply test shaper at ${r} Mbit"; return 1; }
      res=""
      # 进度提示交给 run_iperf 里的转圈, 这里不要再打占位符（会和转圈重叠）
      for _ in 1 2 3; do res=$(run_iperf "$peer" "$dur" "$par"); [ -n "$res" ] && break; sleep 8; done
      if [ -z "$res" ]; then printf '  %-10s %12s %9s %8s  %s\n' "$r" "-" "-" "-" "peer busy, skipped"; continue; fi
      gp=$(echo "$res" | awk '{print $1}'); rt=$(echo "$res" | awk '{print $2}')
      lp=$(loss_pct "$rt" "$gp" "$dur")
      verdict="ok"
      # 第一档的丢包率当基线: 有些线路本底就有一点损, 拿绝对阈值一刀切会把它误判成拐点
      [ -z "$BASE_LOSS" ] && BASE_LOSS="$lp"
      # 判定用丢包率而非绝对重传数 —— 见 loss_pct 上方注释.
      # 单次跳变可能只是公共节点被别人占用, 所以要复测: 3 次里 ≥2 次跳变才确认.
      if is_spike "$lp"; then
        local hits=1 j
        for j in 2 3; do
          sleep "$GAP"
          local r2 g2 t2 l2
          r2=$(run_iperf "$peer" "$dur" "$par"); [ -z "$r2" ] && continue
          g2=$(echo "$r2" | awk '{print $1}'); t2=$(echo "$r2" | awk '{print $2}')
          l2=$(loss_pct "$t2" "$g2" "$dur")
          printf '  %-10s %12s %9s %8s  %s\n' "${r} (#${j})" "$g2" "$t2" "$l2" "recheck"
          is_spike "$l2" && hits=$(( hits + 1 ))
        done
        if [ "$hits" -ge 2 ]; then
          printf '  %-10s %12s %9s %8s  %s\n' "$r" "$gp" "$rt" "$lp" "$(_c '0;31' "loss spike (${hits}/3)")"
          BROKE_AT=$r; return 0
        fi
        printf '  %-10s %12s %9s %8s  %s\n' "$r" "$gp" "$rt" "$lp" "$(_c '0;33' "transient (1/3), ignored")"
      fi
      # 吞吐远低于限速值、重传却很低 = 整形器压根没被触发, 瓶颈在对端.
      # 「重传低」这个条件必不可少：吞吐低但重传高是真撞限速器, 那是有效数据.
      if awk -v g="$gp" -v r="$r" 'BEGIN{exit !(g < r*0.7)}' 2>/dev/null; then
        SLOW_HITS=$(( SLOW_HITS + 1 ))
        printf '  %-10s %12s %9s %8s  %s\n' "$r" "$gp" "$rt" \
          "$(_c '0;33' "only $(awk -v g="$gp" -v r="$r" 'BEGIN{printf "%d", g*100/r}')% of target")"
        [ "$SLOW_HITS" -ge 3 ] && { PEER_TOO_SLOW=1; return 0; }
        LAST_OK=$r; prev_gp=$gp; sleep "$GAP"; continue
      fi
      SLOW_HITS=0
      # 吞吐不再增长也说明到顶了
      if awk -v x="$gp" -v y="$prev_gp" 'BEGIN{exit !(y>0 && x < y*1.01)}'; then verdict="no further gain"; fi
      printf '  %-10s %12s %9s %8s  %s\n' "$r" "$gp" "$rt" "$lp" "$verdict"
      LAST_OK=$r; prev_gp=$gp
      sleep "$GAP"
    done
  }

  # ── 不限速探测 ──────────────────────────────────────────────────────────
  # 直接放开跑一次: 丢包低 = 没东西在打你 = 不用整形; 丢包高 = 有限速器, 再去找它.
  #
  # 关键: 拐点在【不限速吞吐之上】, 不是之下. 打穿限速器会让吞吐掉下来 ——
  # LA 机不限速 481 Mbps / 丢包 5.70%, 而真实拐点在 530(限到 530 反而跑 499);
  # 美国机不限速 1262 / 3.44%, 拐点 1340. 从不限速吞吐往下找会直接错过.
  #
  # 用单流: 多流的丢包归因不干净, 而且这个项目面向国内优化线路, 单流是实际场景.
  local ug="" ulp=""
  if [ -z "$user_range" ]; then
    info "Unshaped probe (no rate limit, ${dur}s, 1 stream)"
    printf '  %-10s %12s %9s %8s  %s\n' "Rate/Mbit" "Goodput/Mbps" "Retrans" "Loss%" "Verdict"
    tc qdisc del dev "$iface" root 2>/dev/null
    tc qdisc add dev "$iface" root fq 2>/dev/null
    local ures urt
    for _ in 1 2 3; do ures=$(run_iperf "$peer" "$dur" 1); [ -n "$ures" ] && break; sleep 8; done
    qdisc_restore
    [ -n "$ures" ] || { warn "unshaped probe failed, check the peer"; return 2; }
    ug=$(echo "$ures" | awk '{print $1}'); urt=$(echo "$ures" | awk '{print $2}')
    ulp=$(loss_pct "$urt" "$ug" "$dur")

    if awk -v g="$ug" -v c="$cap" 'BEGIN{exit !(g > c)}'; then
      printf '  %-10s %12s %9s %8s  %s\n' "none" "$ug" "$urt" "$ulp" "above cap"
      echo
      warn "不限速就能跑 ${ug} Mbps, 超过 ${cap} Mbit 的扫描上限."
      echo "  本工具主要面向国内优化线路, 这个带宽下整形基本不会触发."
      mkdir -p "$STATE_DIR"; printf 'NO_KNEE=1\nABOVE_CAP=%s\nUNSHAPED=%s\n' "$cap" "$ug" > "$STATE_DIR/sweep.result"
      traffic_report
      return 3
    fi

    if ! awk -v l="$ulp" -v t="$thresh" 'BEGIN{exit !(l > t)}'; then
      printf '  %-10s %12s %9s %8s  %s\n' "none" "$ug" "$urt" "$ulp" "ok"
      echo
      warn "不限速跑 ${ug} Mbps, 丢包 ${ulp}%, 未检测到限速器."
      mkdir -p "$STATE_DIR"; printf 'NO_KNEE=1\nUNSHAPED=%s\n' "$ug" > "$STATE_DIR/sweep.result"
      traffic_report
      return 3
    fi

    printf '  %-10s %12s %9s %8s  %s\n' "none" "$ug" "$urt" "$ulp" "$(_c '0;31' 'loss -- policer present')"
    # 拐点在 ug 之上, 所以区间从 ug 稍下方起, 往上扫
    # 打穿限速器后 goodput 会掉下来, 丢得越狠掉得越多, 所以上界要按丢包率放宽:
    # 24% 丢包时真实拐点可能比 1.25×goodput 高得多(群里碰到过 177Mbps/24% 的例子).
    lo=$(awk -v g="$ug" 'BEGIN{printf "%d", g*0.95}')
    hi=$(awk -v g="$ug" -v c="$cap" -v l="$ulp" 'BEGIN{
      k = 1.25 + l/100*2          # 丢包越高, 真实拐点离 goodput 越远
      if (k > 2.5) k = 2.5
      v = g*k; if (v > c) v = c
      printf "%d", v }')
    [ -n "$nominal" ] || nominal=$(awk -v g="$ug" 'BEGIN{printf "%d", g}')
    [ -n "$step" ] || step=$(calc_step "$nominal")
    info "Policer present, scanning ${lo} -> ${hi} Mbit"
  fi

  echo
  info "Scanning ${lo} -> ${hi} Mbit, step ${step}, ${dur}s each, threshold loss > ${thresh}%"
  printf '  %-10s %12s %9s %8s  %s\n' "Rate/Mbit" "Goodput/Mbps" "Retrans" "Loss%" "Verdict"
  scan_range "$lo" "$hi" "$step"

  if [ "$PEER_TOO_SLOW" = 1 ]; then
    echo
    trap - INT TERM HUP
    restore_qdisc
    [ "$WIZARD" = 1 ] && printf '\n  %s════ 结果 ══════════════════════════════════════════════%s\n' "$bold" "$plain"
    echo
    warn "对端速率不够, 无法测出本机限速器 —— 已暂停调优."
    echo
    echo "  怎么办："
    echo "    1) 换一个更快的对端. 对端带宽必须明显高于本机（${nominal}Mbps）"
    echo "    2) 直接用公共节点（选对端时回车）, Leaseweb 机房带宽足够"
    echo "    3) 如果确定本机带宽没那么高, 重跑时把带宽填成实际值"
    echo
    info "基础调优（拥塞控制 / 缓冲区）已生效."
    traffic_report
    return 2
  fi

  # 粗扫只能定位到「拐点在 LAST_OK 与 BROKE_AT 之间」, 区间宽度就是步长.
  # 在这个区间用 1/4 步长再扫一遍, 把真实上限找准 —— 步长 20 时能多挖回十几 Mbps.
  if [ "$refine" = 1 ] && [ -n "$LAST_OK" ] && [ -n "$BROKE_AT" ] && [ $(( BROKE_AT - LAST_OK )) -gt 5 ]; then
    local fine coarse_broke
    coarse_broke=$BROKE_AT                       # 先存下粗扫的上界, 下面会被 scan_range 重置
    fine=$(( step / 4 )); [ "$fine" -lt 5 ] && fine=5
    echo
    info "Knee between ${LAST_OK} and ${coarse_broke}, refining with step ${fine}"
    printf '  %-10s %12s %9s %8s  %s\n' "Rate/Mbit" "Goodput/Mbps" "Retrans" "Loss%" "Verdict"
    BROKE_AT=""
    scan_range $(( LAST_OK + fine )) $(( coarse_broke - fine )) "$fine"
    # 细扫在更细的档位上可能都不触发阈值(拐点就在 coarse_broke 那一档).
    # 不恢复的话 BROKE_AT 是空的, 后面会误判成"未检测到限速器"而不整形 ——
    # 群里实测碰到: 粗扫 536 已经 0.47%-0.63% 丢包, 细扫 521/526/531 都干净,
    # 结果报"未检测到限速器". 粗扫的结论必须保留.
    [ -n "$BROKE_AT" ] || BROKE_AT="$coarse_broke"
  fi

  echo
  trap - INT TERM HUP
  restore_qdisc
  echo
  local knee="$LAST_OK"
  [ -n "$knee" ] || { warn "no usable rate measured, check that the peer is reachable"; return 2; }

  # 扫到区间上界都没有丢包跳变 —— 说明扫描范围内不存在限速器.
  # 早期版本把区间上界当成拐点, 于是给一台根本没有 policer 的机器套了个上限
  # (用户一台 500M 标称的机器被设成 585, 而它实际能跑 9.3 Gbps).
  if [ -z "$BROKE_AT" ]; then
    echo
    if [ -n "$ug" ] && awk -v l="${ulp:-0}" -v t="$thresh" 'BEGIN{exit !(l > t)}'; then
      # 不限速时明明高丢包, 说明限速器确实存在, 只是不在扫描范围内 ——
      # 这跟"没有限速器"是两回事, 不能混为一谈.
      warn "不限速时丢包 ${ulp}%, 但扫到上界 ${hi} Mbit 仍未定位到拐点."
      echo "  限速器应该存在, 只是不在本次扫描范围内. 可以扩大范围重扫:"
      echo "    $(disp) sweep --peer <对端> --from ${hi} --to $(( hi * 2 ))"
      mkdir -p "$STATE_DIR"; printf 'NO_KNEE=1\nOUT_OF_RANGE=1\nSCANNED_TO=%s\n' "$hi" > "$STATE_DIR/sweep.result"
      traffic_report
      return 3
    fi
    warn "扫到 ${hi} Mbit 仍未出现丢包跳变, 未检测到限速器."
    mkdir -p "$STATE_DIR"; printf 'NO_KNEE=1\nSCANNED_TO=%s\n' "$hi" > "$STATE_DIR/sweep.result"
    traffic_report
    return 3
  fi
  # 安全余量按标称带宽分档. 早期用固定 20Mbit, 在 300M 机器上白丢 19Mbps
  # （实测 300 档重传比 280 档还少）, 说明一个数字套所有带宽不合理.
  [ -n "$margin" ] || margin=$(calc_margin "$nominal")
  local final=$(( knee - margin )); [ "$final" -lt 1 ] && final=$knee
  mkdir -p "$STATE_DIR"; echo "KNEE=$knee"$'\n'"RECOMMEND=$final" > "$STATE_DIR/sweep.result"
  # 一键流程里这些数字由 wizard 在「结果」里统一呈现, 这里只出执行日志
  if [ "$WIZARD" = 1 ]; then
    ok "Knee ${knee} Mbit, margin ${margin} Mbit -> shape at ${final} Mbit"
    return 0
  fi
  ok "实测上限 ${knee} Mbit, 按 ${nominal}M 档位退 ${margin} 余量 → 建议整形值 ${final} Mbit"
  echo
  echo "  应用: $(disp) shape --rate $final"
  echo "  (扫描本身不会改变整形配置, 上面这条才会)"
  traffic_report
}

# ── 验证与状态 ──────────────────────────────────────────────────────────────
cmd_status(){
  local iface; iface=$(detect_iface)
  echo "── Current configuration ──"
  kv "Kernel"      "$(uname -r)"
  kv "Congestion"  "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  kv "Default qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  kv "Active qdisc" "$(tc qdisc show dev "$iface" 2>/dev/null | head -1 | awk '{print $2}')"
  kv "Egress shaper" "$(tc class show dev "$iface" 2>/dev/null | grep -oE 'rate [0-9]+[MKG]bit' | head -1 || echo 'none')"
  kv "tcp_rmem"    "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr '\t' ' ')"
  kv "tcp_wmem"    "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr '\t' ' ')"
  kv "tcp_mem"     "$(sysctl -n net.ipv4.tcp_mem 2>/dev/null | awk '{printf "%.0fM/%.0fM/%.0fM", $1*4/1024,$2*4/1024,$3*4/1024}')"
  kv "Backlog"     "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
  kv "initcwnd"    "$(ip route show default | grep -oE 'initcwnd [0-9]+' || echo '默认(10)')"
  kv "tcpfit conf" "$([ -f "$SYSCTL_FILE" ] && echo applied || echo absent)"
  kv "Shaper svc"  "$(systemctl is-enabled tcpfit-qdisc.service 2>/dev/null || echo 未安装)"
  kv "Snapshot"    "$([ -f "$SNAPSHOT" ] && echo "$SNAPSHOT" || echo 无)"
  echo
  echo "── Health ──"
  local out rt
  out=$(awk '/^Tcp: [0-9]/{print $12, $13}' /proc/net/snmp)
  rt=$(echo "$out" | awk '{if($1>0) printf "%.3f%%", $2*100/$1; else print "n/a"}')
  kv "Retrans (boot)" "$rt  (cumulative since boot; use Verify for current)"
  kv "qdisc drops" "$(tc -s class show dev "$iface" 2>/dev/null | grep -oP 'dropped \K[0-9]+' | head -1 || echo n/a)"
  kv "Memory"      "$(free -m | awk '/Mem:/{print "已用 "$3"MB / 可用 "$7"MB / 共 "$2"MB"}')"
  kv "Swap"        "$(free -m | awk '/Swap:/{if($2==0) print "none (recommended on low-memory hosts)"; else print $3"/"$2" MB"}')"
  # grep -c 无匹配时输出 0 但退出码 1, 不能用 || 兜底, 否则会打印两个 0
  kv "OOM (1h)"    "$(journalctl --since '-1 hour' 2>/dev/null | grep -c 'oom-kill') in last hour"
}

# 验证「本机端口能力」. 刻意用近端对端 —— 测的是服务器出口能发多快、
# 整形有没有生效, 不是到国内的速度（那取决于线路质量, 见 cmd_cntest）.
# 实测 + 判定拆开：一键流程要把执行日志（英文）和结论（中文）分在两段里打印.
VS1=""; VR1=""; VS4=""; VR4=""; VDUR=10
verify_measure(){
  local peer="$1" res
  VS1=""; VR1=""; VS4=""; VR4=""
  res=$(run_iperf "$peer" "$VDUR" 1); [ -n "$res" ] && { VS1=$(echo "$res"|awk '{print $1}'); VR1=$(echo "$res"|awk '{print $2}'); }
  sleep 3
  res=$(run_iperf "$peer" "$VDUR" 4); [ -n "$res" ] && { VS4=$(echo "$res"|awk '{print $1}'); VR4=$(echo "$res"|awk '{print $2}'); }
}

# 打印验证结果表 + 结论. $1 = 当前整形值(Mbit, 可空)
#
# 判定一律用丢包率, 不用绝对重传次数 —— 同样 14574 次, 300M 机上是 5.6% 的灾难,
# 9G 机上只有 0.19% 属正常. sweep 早就改成丢包率了, verify 这里当时漏了同步,
# 结果给一台 5Gbps 的机器报"重传偏高, 整形值可能设高了", 而那台根本没装整形.
#
#   < 0.05%    干净
#   0.05-0.5%  略高, 通常不影响
#   0.5-1%     偏高, 值得查
#   > 1%       很糟, 多半撞了限速器或链路有问题
# 参照: 实测干净的机器在 0.0013%-0.0017%, 真撞限速器是 1.35%-6.50%.
verify_verdict(){
  local target="${1:-}" lp1="" lp4=""
  [ -n "$VS1" ] && [ -n "$VR1" ] && lp1=$(loss_pct "$VR1" "$VS1" "$VDUR")
  [ -n "$VS4" ] && [ -n "$VR4" ] && lp4=$(loss_pct "$VR4" "$VS4" "$VDUR")
  echo "  验证"
  printf '      %s %s %s %s\n' "$(_pad "" 14)" "$(_rpad "吞吐 Mbps" 12)" "$(_rpad "重传" 9)" "$(_rpad "丢包率" 10)"
  printf '      %s %s %s %s\n' "$(_pad "单流" 14)"     "$(_rpad "${VS1:-测试失败}" 12)" "$(_rpad "${VR1:--}" 9)" "$(_rpad "${lp1:+${lp1}%}" 10)"
  printf '      %s %s %s %s\n' "$(_pad "4 流并发" 14)" "$(_rpad "${VS4:-测试失败}" 12)" "$(_rpad "${VR4:--}" 9)" "$(_rpad "${lp4:+${lp4}%}" 10)"
  echo
  # 吞吐和整形值比, 给结论而不是丢一堆数字
  if [ -n "$VS4" ] && [ -n "$target" ] && [ "$target" -gt 0 ] 2>/dev/null; then
    local pct; pct=$(awk -v a="$VS4" -v b="$target" 'BEGIN{printf "%.0f", a*100/b}')
    if   [ "$pct" -ge 90 ] 2>/dev/null; then ok "达到整形值的 ${pct}%, 端口能力正常"
    elif [ "$pct" -ge 75 ] 2>/dev/null; then info "达到整形值的 ${pct}%, 偏低但可接受（对端可能被其他人占用）"
    else warn "只达到整形值的 ${pct}%, 建议换个对端重测"; fi
  fi
  [ -n "$lp4" ] || return 0
  # 没有整形时不能说"整形值设高了" —— 用户会被指去调一个根本不存在的东西
  local advice
  if [ -n "$target" ] && [ "$target" -gt 0 ] 2>/dev/null; then
    advice="整形值可能设高了, 可以重跑菜单 3 重新找拐点"
  else
    advice="这台没有应用整形. 高丢包来自链路本身或未被识别的限速器, 可以跑菜单 3 试着扫一次拐点"
  fi
  if   awk -v l="$lp4" 'BEGIN{exit !(l < 0.05)}'; then ok   "丢包 ${lp4}%, 链路干净"
  elif awk -v l="$lp4" 'BEGIN{exit !(l < 0.5)}';  then ok   "丢包 ${lp4}%, 略高, 通常不影响"
  elif awk -v l="$lp4" 'BEGIN{exit !(l < 1)}';    then warn "丢包 ${lp4}%, 偏高 —— ${advice}"
  else                                                 warn "丢包 ${lp4}%, 很糟 —— ${advice}"; fi
}

cmd_verify(){
  local peer="" peer_name="" peer_rtt=""
  while [ $# -gt 0 ]; do
    case "$1" in --peer) peer="$2"; shift 2 ;; --name) peer_name="$2"; shift 2 ;; *) shift ;; esac
  done
  local iface shaper; iface=$(detect_iface)
  shaper=$(tc class show dev "$iface" 2>/dev/null | grep -oE 'rate [0-9]+[MKG]bit' | head -1 | awk '{print $2}')

  echo
  printf '  %s本机端口能力验证%s\n' "$bold" "$plain"
  rule
  echo "  测的是：服务器出口能发多快、整形有没有生效"
  echo "  不测：到国内的速度（那取决于线路质量, 跟服务器配置无关）"
  echo

  if [ -z "$peer" ]; then
    warn "没有可用对端, 只显示配置"
    cmd_status; return 0
  fi
  peer_rtt=$(ping $IP_FAMILY -c 2 -q -W 2 "$peer" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
  printf "  对端    %s   RTT %sms   端口 %s\n" "$peer" "${peer_rtt:-?}" "$PEER_PORT"
  printf "  整形    %s\n" "${shaper:-未设置}"
  echo
  command -v iperf3 >/dev/null || { warn "无 iperf3, 跳过实测"; return 0; }

  verify_measure "$peer"
  verify_verdict "${shaper%Mbit}"
  rule
}

# ── 检查更新 ────────────────────────────────────────────────────────────────
cmd_update(){
  need_root
  command -v curl >/dev/null || die "需要 curl"
  # 菜单调进来时带 --from-menu: 更新完要用新版本 exec 掉自己, 否则用户在同一个
  # 菜单里接着操作, 跑的仍是内存里的旧代码.
  local from_menu=0
  [ "${1:-}" = "--from-menu" ] && { from_menu=1; shift; }
  info "检查更新…"
  local latest
  # 只看 release, 不看 main —— main 可能领先于任何已发布版本
  latest=$(curl -fsSL --max-time 10 "https://api.github.com/repos/Kylin010/tcpfit/releases/latest" 2>/dev/null \
           | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/')
  [ -n "$latest" ] || die "查不到最新版本, 检查网络或稍后再试" 2

  if [ "$latest" = "$VERSION" ]; then ok "已是最新版本 v$VERSION"; return 0; fi
  # 用 sort -V 比版本号, 字符串比较会把 0.3.10 判成小于 0.3.9
  if [ "$(printf '%s\n%s\n' "$VERSION" "$latest" | sort -V | tail -1)" = "$VERSION" ]; then
    ok "当前 v$VERSION 比已发布的 v$latest 还新（开发版）"; return 0
  fi

  echo
  _conf "当前版本" "v$VERSION"
  _conf "最新版本" "v$latest"
  _conf "更新说明" "https://github.com/Kylin010/tcpfit/releases/tag/v$latest"
  echo
  confirm "  现在更新？" y || { info "已取消"; return 0; }

  # 从 release 下, 用发布的 SHA256SUMS 校验. 只对比 tcpfit.sh 那一行 ——
  # SHA256SUMS 里还有 install.sh, 直接 sha256sum -c 会因为文件不在而失败.
  local dl; dl=$(mktemp -d)
  local base="https://github.com/Kylin010/tcpfit/releases/download/v$latest"
  if ! curl -fsSL --max-time 60 "$base/tcpfit.sh" -o "$dl/tcpfit.sh"; then
    rm -rf "$dl"; die "下载失败" 2
  fi
  if command -v sha256sum >/dev/null && curl -fsSL --max-time 20 "$base/SHA256SUMS" -o "$dl/SHA256SUMS"; then
    if ! ( cd "$dl" && grep ' tcpfit\.sh$' SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ); then
      rm -rf "$dl"; die "SHA256 校验不通过, 未更新" 2
    fi
    info "SHA256 校验通过"
  else
    warn "取不到 SHA256SUMS 或没有 sha256sum, 退回版本号校验"
  fi
  if ! { head -1 "$dl/tcpfit.sh" | grep -q '^#!' && grep -q "^VERSION=\"$latest\"" "$dl/tcpfit.sh"; }; then
    rm -rf "$dl"; die "下载的文件校验不通过, 未更新" 2
  fi
  # 不能原地覆盖 —— 正在执行的就是 $SELF_PATH, 而 bash 是按文件偏移增量读脚本的,
  # 原地改写有可能让它读到新文件的错位内容（两个版本长度还不一样）.
  # 先写同目录的 .new 再 mv: rename 是原子的, 换新 inode, 旧 inode 对当前进程保持有效.
  if ! install -m 755 "$dl/tcpfit.sh" "${SELF_PATH}.new" || ! mv -f "${SELF_PATH}.new" "$SELF_PATH"; then
    rm -f "${SELF_PATH}.new"; rm -rf "$dl"; die "写入 $SELF_PATH 失败" 2
  fi
  rm -rf "$dl"
  ok "已更新到 v$latest"
  info "配置和快照不受影响."

  # 关键: 磁盘上换了, 但当前进程内存里跑的还是旧代码.
  # 早期版本这里只打一句"重跑一次调优", 用户就在同一个菜单里按 1 —— 跑的仍是旧版本,
  # 于是"更新了但 bug 还在". 有客户真踩过, 排查了很久才定位到是这里.
  if [ "$from_menu" = 1 ]; then
    info "以新版本重启…"
    echo
    exec "$SELF_PATH" menu
  fi
  warn "当前进程跑的仍是 v${VERSION} 的代码, 重新运行 tcpfit 才会用上新版本."
}

# ── 交互式菜单 ──────────────────────────────────────────────────────────────
#
# 设计原则：用户只需要回答"这机器干什么用的", 其余全部自动.
# 尤其是 iperf3 对端 —— 让用户自己挑服务器是最大的使用门槛, 这里自动 ping 一圈选最近的.

# 公共 iperf3 服务器池. 挑选标准：长期在线、允许匿名测试、地理分布覆盖主要机房区域.
# 公共 iperf3 测速节点池. 格式: 主机|地区|提供商
#
# 这些是第三方免费提供的公共测试服务器, sweep 会向它们发送测试流量.
# 节点来源与实测稳定性（2026-08 在欧洲机器上各测 3 次握手）：
#   Leaseweb   全球机房, 18 节点中 15 个 3/3 —— 最稳, 优先用
#   Clouvider  5 节点中仅 2 个 3/3 —— 时好时坏, 作备选
#   OVH        新加坡节点 3/3
# 注: 早期用 timeout 15 测稳定性, 对 280ms+ 的远节点连握手都不够, 误判成不可用.
# 判定节点好坏不能用固定超时 —— 和 RTT 一刀切是同一类错误.
# 完整公共列表见 https://iperf3serverlist.net
PEER_POOL="
speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
speedtest.syd12.au.leaseweb.net|悉尼|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
lon.speedtest.clouvider.net|伦敦|Clouvider
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.sea11.us.leaseweb.net|西雅图|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.chi11.us.leaseweb.net|芝加哥|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
speedtest.mia11.us.leaseweb.net|迈阿密|Leaseweb
speedtest.mtl2.ca.leaseweb.net|蒙特利尔|Leaseweb
"

# 自动挑选对端：先按 RTT 排序, 再逐个验证 iperf3 真的能用（公共服务器常年占线）
auto_pick_peer(){
  local best="" cand rtt name line
  info "自动选择测速对端（测的是本机端口上限, 越近越准）…" >&2
  # 并行 ping 全部节点. 串行时 17 个节点 × 最长 4 秒 = 最坏 68 秒, 用户干等.
  local sorted="" prov tmpd
  tmpd=$(mktemp -d)
  while IFS='|' read -r cand name prov; do
    [ -z "$cand" ] && continue
    ( r=$(ping $IP_FAMILY -c 2 -q -W 2 "$cand" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%.0f", $5}')
      [ -n "$r" ] && echo "$r $cand $name $prov" > "$tmpd/$cand" ) &
  done <<< "$PEER_POOL"
  wait
  sorted=$(cat "$tmpd"/* 2>/dev/null); rm -rf "$tmpd"
  [ -n "$sorted" ] || { echo ""; return 1; }
  # RTT 分级：sweep 测的是本机端口上的限速器, 对端越近越准.
  #   ≤ideal  最佳, 链路干扰可忽略
  #   ≤accept 可用, 但要提醒用户结果可能偏保守
  #   >accept 拒绝, 宁可失败也不给错误结论
  # 早期只有一个 60ms 硬阈值, 结果香港机器上新加坡 61ms 被卡掉、整个流程失败 —— 太死板.
  local ideal="${NETTUNE_PEER_IDEAL_RTT:-50}"
  local accept="${NETTUNE_PEER_MAX_RTT:-100}"
  local fallback="" fallback_rtt=""
  while read -r rtt cand name prov; do
    [ -z "$cand" ] && continue
    if [ "$rtt" -gt "$accept" ] 2>/dev/null; then
      printf '  %-34s %-10s %-10s RTT %-6s %s\n' "$cand" "$name" "$prov" "${rtt}ms" "too far, skipped" >&2
      continue
    fi
    printf '  %-34s %-10s %-10s RTT %-6s ' "$cand" "$name" "$prov" "${rtt}ms" >&2
    # 先探端口, 把"根本不跑 iperf3/被墙"和"跑着但占线"分开 ——
    # 早期两者都报"占线", 用户完全看不出真实原因.
    # 必须轮换: 只探 5201 的话, 出站封了 5201 的机房上所有节点都会被误判(见 PROBE_PORTS).
    if ! probe_peer_port "$cand"; then
      echo "port closed (tried $PROBE_PORTS)" >&2; continue
    fi
    local pport="$PROBE_PORT_OK"
    [ "$pport" = 5201 ] || printf '%s ' "$(_c '0;33' "5201→$pport")" >&2
    # 没装 iperf3 时无法做占线探测（iperf3 要等确认之后才装）,
    # 降级成"端口通就算可用". 选错了也不致命 —— run_iperf 本身会换端口重试.
    if ! command -v iperf3 >/dev/null 2>&1; then
      printf '%s\n' "$(_c '0;32' "reachable (port $pport)")" >&2
      echo "$cand:$pport"; return 0
    fi
    # 这些公共节点都开十个 iperf3 实例（公共列表里标的就是端口范围）.
    # 早期只试 5201, 等于放着 9 个空闲实例不用去跟全世界抢一个, 动不动就"占线".
    # 从预检探通的那个端口起试 —— 5201 被封时能省掉一次 25 秒的超时等待.
    local gp="" try
    for try in $(port_order "$pport"); do
      if timeout $TIMEOUT_FG 25 iperf3 $IP_FAMILY -c "$cand" -p "$try" -t 3 -P 1 >/dev/null 2>&1; then gp="$try"; break; fi
    done
    if [ -n "$gp" ]; then
      if [ "$rtt" -le "$ideal" ] 2>/dev/null; then
        echo "${green}available${plain} (port $gp)" >&2; best="$cand:$gp"; break
      fi
      echo "available (port $gp, distant — held as fallback)" >&2
      [ -z "$fallback" ] && { fallback="$cand:$gp"; fallback_rtt="$rtt"; }
    else
      echo "all $(echo $PORT_POOL | wc -w) ports busy" >&2
    fi
    sleep 2
  done <<< "$(echo "$sorted" | sort -n)"

  if [ -z "$best" ] && [ -n "$fallback" ]; then
    best="$fallback"
    echo >&2
    warn "最近的可用对端是 ${fallback_rtt}ms（理想是 ${ideal}ms 以内）." >&2
    warn "距离越远, 链路本身的丢包抖动越会混进测量, 拐点可能偏保守." >&2
    warn "结果仍然可用, 只是可能没榨到极限." >&2
  fi

  if [ -z "$best" ]; then
    warn "没找到 ${accept}ms 以内且空闲的公共测速服务器." >&2
    warn "公共服务器一次只接一个测试, 等几分钟再试通常就有了." >&2
    warn "或者自己开一台近处的机器跑 iperf3 -s, 然后用 --peer 指定." >&2
    return 1
  fi
  echo "$best"
}

# 验证对端路径是否干净. RTT 只是代理指标 —— 真正要的是路径没有丢包干扰测量.
# 用标称带宽的 40% 跑一次：这个速率远低于任何限速器, 此时还有明显重传,
# 就说明是链路本身在丢包, 拿它测拐点必然测偏.
validate_peer(){
  local peer="$1" nominal="$2" iface="$3"
  local rate=$(( nominal * 40 / 100 )); [ "$rate" -lt 20 ] && rate=20
  qdisc_save "$iface"
  # 早期版本这里没有任何 trap: 中断就把机器留在标称 40% 的限速上, 直到重启
  trap 'qdisc_restore; exit 130' INT TERM HUP
  apply_test_shaper "$iface" "$rate" || { qdisc_restore; echo "unreachable"; return 1; }
  local res rt
  for _ in 1 2; do res=$(run_iperf "$peer" 8 2); [ -n "$res" ] && break; sleep 5; done
  trap - INT TERM HUP
  qdisc_restore
  [ -n "$res" ] || { echo "unreachable"; return 1; }
  local gp; gp=$(echo "$res" | awk '{print $1}'); rt=$(echo "$res" | awk '{print $2}')
  # 对端连 40% 速率都跑不到, 说明它本身就比本机慢, 拿它测限速器毫无意义.
  if awk -v g="$gp" -v r="$rate" 'BEGIN{exit !(g < r*0.7)}' 2>/dev/null; then
    echo "slow:$gp/$rate"; return 1
  fi
  # 低速率下丢包率应该接近 0. 比 sweep 更严(0.05% vs 0.1%), 因为跑的是 40% 速率.
  local lp; lp=$(loss_pct "$rt" "$gp" 8)
  if awk -v l="$lp" 'BEGIN{exit !(l > 0.05)}' 2>/dev/null; then echo "dirty:${rt}(${lp}%)"; return 1; fi
  echo "clean:$rt"
}

# 曾用它清"超前输入"防止杂散回车误答, 但它会把管道/脚本喂进来的合法输入
# 一起吃掉（实测卡在带宽提示不动）, 手速快的用户也会中招.
# 主操作默认值改成 y 之后, 杂散回车本身已无害, 所以不再调用.
flush_input(){ :; }

ask(){  # ask "问题" "默认值"  -> 回显用户输入或默认值
  local q="$1" d="${2:-}" a
  if [ -n "$d" ]; then printf '%s [%s]: ' "$q" "$d" >&2; else printf '%s: ' "$q" >&2; fi
  read -r a </dev/tty || a=""
  echo "${a:-$d}"
}

# confirm "问题" [默认]  -> 0=是 1=否. 默认 y 时空回车即同意.
# 主操作（如"开始调优？"）必须默认 y —— 用户就是为这个来的,
# 一个杂散回车不该让整个流程静默取消.
confirm(){
  local d="${2:-n}" a p
  [ "$d" = y ] && p="(Y/n)" || p="(y/N)"
  a=$(ask "$1 $p" "$d")
  [[ "$a" =~ ^[Yy] ]]
}

# 框宽固定 48 列. 每行按显示宽度补齐后再包边框 ——
# 手写空格对不齐, 因为 CJK 占 2 列而框线字符占 1 列.
BOX_W=56
_row(){ # _row "<内容>" [颜色代码]
  local txt="$1" col="${2:-}" pad
  pad=$(( BOX_W - $(_dispw "$txt") ))
  [ "$pad" -lt 0 ] && pad=0
  if [ -n "$col" ]; then printf '│\033[%sm%s\033[0m%*s│\n' "$col" "$txt" "$pad" ""
  else printf '│%s%*s│\n' "$txt" "$pad" ""; fi
}
_sep(){ printf '│'; printf '─%.0s' $(seq $BOX_W); printf '│\n'; }
_top(){ printf '╔'; printf '─%.0s' $(seq $BOX_W); printf '╗\n'; }
_bot(){ printf '╚'; printf '─%.0s' $(seq $BOX_W); printf '╝\n'; }

# 菜单条目：中文名、英文名、耗时三列各自按显示宽度补齐.
# 手写空格必然错位 —— 中文占 2 列,"~10 min" 这种右列一长就把右边框顶出去.
_item(){ # _item <编号> <中文> <英文> [耗时]
  _row "$(printf '  %s. %s %s %s ' "$1" "$(_pad "$2" 10)" "$(_pad "$3" 30)" "$(_rpad "${4:-}" 8)")"
}

banner(){
  local iface cc shaper ram cores tuned
  iface=$(detect_iface)
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  shaper=$(tc class show dev "$iface" 2>/dev/null | grep -oE 'rate [0-9]+[MG]bit' | head -1 | awk '{print $2}')
  ram=$(detect_ram_mb); cores=$(detect_cores)
  [ -f "$SYSCTL_FILE" ] && tuned="Tuned" || tuned="Stock"
  clear 2>/dev/null || true
  echo
  _top
  _row "$(printf '  tcpfit - VPS TCP Optimization%s ' "$(_rpad "v$VERSION" 23)")" '0;32'
  _row "  本脚本由 kylin010 编写和维护"
  _row "  github.com/Kylin010/tcpfit"
  _sep
  _row "  0. Exit"
  _item 1 "一键调优" "Auto-tune (recommended)"   "~10 min"
  _item 2 "基础调优" "Base tuning only"          "~1 min"
  _item 3 "拐点测试" "Policer sweep"             "~8 min"
  _item 4 "加 swap"  "Add swap (low-memory box)"
  _sep
  _item 5 "查看状态" "Status"
  _item 6 "端口验证" "Verify port capability"    "~1 min"
  _item 7 "回滚改动" "Rollback all changes"
  _item 8 "检查更新" "Check for updates"
  _bot
  printf "  %-9s %s core / %s MB / %s\n" "Machine" "$cores" "$ram" "$(uname -r)"
  printf "  %-9s cc=%s  shaper=%s  " "Network" "${cc:-?}" "${shaper:-none}"
  [ "$tuned" = Tuned ] && printf "${green}%s${plain}\n" "$tuned" || printf "${yellow}%s${plain}\n" "$tuned"
}

# 一键全自动.
# 设计原则：所有要用户回答的东西集中在最前面（3 个问题）, 确认之后一路跑到底不再打断；
# 执行阶段的日志用英文（都是参数名和数值, 中英混排反而看不清）, 结论用中文.
wizard(){
  WIZARD=1
  local ram; ram=$(detect_ram_mb)
  echo
  echo "  ── 一键调优 ──"
  echo
  rule
  echo "  开始前的说明"
  echo
  echo "  改动前会把当前配置完整备份到"
  echo "      $(_c '1' "$SNAPSHOT")"
  echo "  包含拥塞控制、全部缓冲区参数、qdisc、路由等原始值."

  # 协议族: 默认 IPv4; 纯 v6 机器自动走 v6; 双栈才问.
  # 每个分支只说跟这台机器有关的话.
  # 早期版本在这里无条件打一句"测速默认走 IPv4. 检测不到 IPv4 会走 IPv6." ——
  # 本意是说明规则, 但纯 v4 机器(绝大多数)看到的就只有这一行, 而且没有任何一行
  # 确认"检测到了 v4". tcpfit 其他输出全是状态行, 用户就把"检测不到 IPv4"
  # 读成了对自己机器的判定, 以为脚本认错了. 有用户真这么报过.
  if ! have_ipv4; then
    IP_FAMILY="-6"
    ok "本机没有 IPv4, 测速走 IPv6"
  elif have_ipv6; then
    echo
    echo "  本机是 IPv4 + IPv6 双栈, 测速默认走 IPv4."
    echo
    local fam
    while true; do
      fam=$(ask "  用 v4 还是 v6？（回车 = v4）" "v4")
      case "$fam" in
        v4|V4|4) IP_FAMILY="-4"; break ;;
        v6|V6|6) IP_FAMILY="-6"; break ;;
        *) warn "  请输入 v4 或 v6" ;;
      esac
    done
    ok "测速走 IPv${IP_FAMILY#-}"
  fi

  # iperf3 单独放在最前面确认 —— 两个原因:
  #   1) 装包是会改系统的操作, 不该在用户点头之前做
  #   2) 选对端那一步要用 iperf3 做占线探测, 所以必须在三个问题之前就位
  local HAVE_IPERF3=1 QN=3
  if command -v iperf3 >/dev/null 2>&1; then
    echo "  iperf3 已经安装 $(iperf3 --version 2>/dev/null | awk 'NR==1{print $2}')"
  else
    echo "  确认带宽之前, tcpfit 需要安装 iperf3 才可以正常运行."
    echo
    if confirm "  安装？" y; then
      echo "    ────────────────────────────────────────"
      if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y iperf3
      elif command -v dnf     >/dev/null; then dnf install -y iperf3
      elif command -v yum     >/dev/null; then yum install -y epel-release; yum install -y iperf3
      # Alpine 的 busybox timeout/pkill 功能不全, 一并装 GNU 版
      elif command -v apk     >/dev/null; then apk add iperf3 coreutils procps
      else warn "认不出包管理器, 请手动安装 iperf3"; fi
      echo "    ────────────────────────────────────────"
    fi
    if command -v iperf3 >/dev/null 2>&1; then
      ok "iperf3 $(iperf3 --version 2>/dev/null | awk 'NR==1{print $2}') 已就绪"
    else
      # 不中止 —— 基础调优(BBR/缓冲区/起步)完全不依赖 iperf3, 那也是收益最大的一部分.
      # 少掉的是: 实测带宽、扫拐点、验证吞吐.
      HAVE_IPERF3=0; QN=2
      echo
      warn "没有 iperf3, 只能做基础调优:"
      warn "  不能实测带宽(要你手填)、不能扫限速器拐点、不能验证吞吐."
      warn "  基础调优本身照做, 那是收益最大的一部分."
    fi
  fi

  # ── 1/3 带宽 ────────────────────────────────────────────────────────────
  step "1/${QN}  确认带宽"
  echo
  echo "    你这台机器的带宽是多少 Mbps？常见 100 / 200 / 300 / 500 / 1000."
  echo
  if [ "$HAVE_IPERF3" = 1 ]; then
    printf "    %s建议手动输入. %s回车会在执行阶段现场实测一个估值……\n" "$yellow" "$plain"
    echo "    跳过扫描. 填 0 表示不做整形（端口没有限速器时选这个）."
    echo "    已经知道限速值？输入 m 跳过拐点扫描直接指定"
  else
    printf "    %s没有 iperf3, 必须手动填一个数字.%s\n" "$yellow" "$plain"
  fi
  echo
  # MANUAL_RATE 的三种状态：""=正常扫描 / 数字=直接按该值整形 / "off"=完全不整形
  local bw MANUAL_RATE=""
  while true; do
    bw=$(ask "  带宽 Mbps" "")
    case "$bw" in
      "")      [ "$HAVE_IPERF3" = 0 ] && { warn "  没有 iperf3, 无法实测, 请手动填一个数字"; continue; }
               bw=auto; break ;;                       # 回车 → 执行阶段实测
      0)       MANUAL_RATE=off; bw=auto; break ;;      # 0 → 不整形, 带宽仍需实测
      m|M)                                             # m → 跳到限速值那一问
        while true; do
          MANUAL_RATE=$(ask "  限速值 Mbit" "")
          [ -z "$MANUAL_RATE" ] && { warn "  请填一个数字, 0 表示不做整形"; continue; }
          [ "$MANUAL_RATE" = 0 ] && { MANUAL_RATE=off; bw=auto; break; }
          if { [ "$MANUAL_RATE" -gt 0 ] && [ "$MANUAL_RATE" -le 100000 ]; } 2>/dev/null; then
            bw="$MANUAL_RATE"; break                   # 限速值同时作为算 BDP 的带宽基准
          fi
          warn "  请输入一个正整数（单位 Mbit）, 或 0 表示不做整形"
        done
        break ;;
      *)
        { [ "$bw" -gt 0 ] && [ "$bw" -le 100000 ]; } 2>/dev/null && break
        warn "  请输入一个正整数（单位 Mbps）, 或 m / 0" ;;
    esac
  done

  # ── 2/3 对端 ────────────────────────────────────────────────────────────
  # 没有 iperf3 就没有对端可言, 整段跳过, 且强制不做整形
  local peer="(不需要)"
  if [ "$HAVE_IPERF3" = 0 ]; then
    MANUAL_RATE="${MANUAL_RATE:-off}"
  else
  step "2/${QN}  确认测速对端"
  echo
  echo "    拐点扫描需要一台对端机器跑 iperf3 服务端."
  echo
  echo "    A) 直接回车 —— 用公共节点（默认）"
  echo "       由以下厂商免费提供, 测试流量会发往它们："
  echo "           Leaseweb / Clouvider / OVH"
  echo "           完整列表见 iperf3serverlist.net"
  echo
  echo "    B) 用你自己的另一台机器"
  echo "       在那台机器上执行这两条："
  printf "           %sapt install -y iperf3%s    # 装 iperf3；已装过会跳过, 不会重装\n" "$green" "$plain"
  printf "           %siperf3 -s%s                # 启动服务端, 默认监听 5201 端口\n" "$green" "$plain"
  echo "       然后在下面填那台机器的 IP, 例如  1.2.3.4"
  printf "       %s本脚本默认连 5201 端口%s；对端换了端口的话填  IP:端口  形式. \n" "$yellow" "$plain"
  echo "       对端要选离本机近的."
  echo
  while true; do
    peer=$(ask "  对端 IP / 域名（回车=公共节点）" "")
    if [ -z "$peer" ]; then
      local picked; picked=$(auto_pick_peer) || die "公共测速服务器暂时都不可用, 稍后再试" 2
      peer="${picked%:*}"; PEER_PORT="${picked##*:}"
      break
    fi
    # 拆主机和端口. 不能只按"最后一个冒号"拆 —— IPv6 地址本身满是冒号:
    #   2001:db8::1  会被拆成 主机=2001:db8: 端口=1, 然后拿着错主机错端口继续跑, 静默出错.
    # 五种形式都要认（不能只收带端口的, 界面上就是教用户填 1.2.3.4 这种裸地址）:
    #   1.2.3.4 / example.com        → 默认 5201
    #   1.2.3.4:5202 / host:5202     → 拆
    #   2001:db8::1                  → 裸 v6, 默认 5201
    #   [2001:db8::1]:5202           → 剥方括号再拆
    # 顺序有讲究: [v6]:port 必须排在 [v6] 前面, 裸 v6 (两个以上冒号) 必须排在 host:port 前面.
    PEER_PORT=5201
    case "$peer" in
      \[*\]:*) PEER_PORT="${peer##*]:}"; peer="${peer%%]:*}"; peer="${peer#\[}" ;;
      \[*\])   peer="${peer#\[}"; peer="${peer%\]}" ;;
      *:*:*)   : ;;
      *:*)     PEER_PORT="${peer##*:}"; peer="${peer%:*}" ;;
    esac
    if ! is_posint "$PEER_PORT" 1 65535; then
      warn "端口必须是 1-65535 之间的整数（IPv6 地址请写成 [地址]:端口）"; echo; continue
    fi
    # 手填的对端当场验一次可达性. 打错 IP 的话不该等到执行阶段才发现 ——
    # 那时前面三个问题都白填了, 而且已经改过 sysctl.
    printf '    检查 %s:%s … ' "$peer" "$PEER_PORT" >&2
    if probe_port "$peer" "$PEER_PORT" 6; then
      printf '%s\n' "$(_c '0;32' '可达')" >&2
      break
    fi
    printf '%s\n' "$(_c '0;31' '连不上')" >&2
    echo "      常见原因: 对端没在跑 iperf3 -s / 端口填错 / 防火墙挡了 / IP 打错"
    echo "      回车可以改用公共节点."
    echo
  done
  fi

  # ── 3/3 用途 ────────────────────────────────────────────────────────────
  step "${QN}/${QN}  机器用途"
  echo
  echo "    1) 代理 / 加速        并发连接多, 缓冲区取保守值（最常见）"
  echo "    2) 大文件传输 / 备份  少数大流, 缓冲区取激进值"
  echo
  local rc role
  rc=$(ask "  选择" "1")
  case "$rc" in 2) role=bulk ;; *) role=proxy ;; esac

  # ── 确认 ────────────────────────────────────────────────────────────────
  echo
  rule
  echo "  确认"
  echo
  if [ "$bw" = auto ]; then
    _conf "带宽" "自动实测（执行阶段测）"
  elif [ -n "$MANUAL_RATE" ]; then
    _conf "带宽" "${bw} Mbps"                      # 手填时余量无意义, 不显示
  else
    _conf "带宽" "${bw} Mbps        整形安全余量 $(calc_margin "$bw") Mbit"
  fi
  case "$MANUAL_RATE" in
    "")  _conf "整形" "实测拐点后自动决定" ;;
    off) _conf "整形" "不做整形" ;;
    *)   _conf "整形" "${MANUAL_RATE} Mbit" ;;
  esac
  [ "$HAVE_IPERF3" = 1 ] && _conf "对端" "${peer}:${PEER_PORT}"
  _conf "用途" "$([ "$role" = bulk ] && echo '大文件传输 / 备份' || echo '代理 / 加速')"
  if [ "$HAVE_IPERF3" = 1 ]; then _conf "iperf3" "$(iperf3 --version 2>/dev/null | awk 'NR==1{print $2}')"
  else _conf "iperf3" "无, 只做基础调优"; fi
  _conf "安装位置" "$SELF_PATH"
  echo
  if [ -n "$MANUAL_RATE" ]; then _conf "预计耗时" "约 1 分钟"
  else                              _conf "预计耗时" "约 10 分钟"; fi
  if [ -n "$MANUAL_RATE" ]; then _conf "预计流量" "很少"
  elif [ "$bw" = auto ]; then   _conf "预计流量" "带宽实测后才能估"
  else
    _conf "预计流量" "约 $(estimate_traffic_gb "$bw") GB"
    _conf ""         "先测一档判断有没有限速器, 没有就到此为止"
  fi
  # 2G 以上扫描代价陡增, 且代理场景的实际流量通常远达不到端口上限.
  # 只提醒, 不阻止 —— 用户可能就是要为大流量场景调.
  if [ -z "$MANUAL_RATE" ] && [ "$bw" != auto ] && [ "$bw" -gt 2000 ] 2>/dev/null; then
    echo
    warn "带宽 ${bw} Mbps 超过 2000, 拐点扫描代价很高."
    echo "      代理场景下实际流量通常远达不到这个值, 整形器很可能从不触发."
    echo "      想跳过的话, 重跑时带宽那一问填 0."
  fi
  rule
  confirm "  开始调优？" y || { info "已取消, 未做任何改动"; return 0; }

  # ══ 执行阶段：全自动, 不再有任何提问 ══════════════════════════════════
  traffic_mark
  printf '\n  %s════ Running ═══════════════════════════════════════════%s\n' "$bold" "$plain"

  printf '\n  %s[1/5] Base tuning%s\n' "$bold" "$plain"
  if [ "$bw" = auto ]; then
    info "Probing bandwidth (4 streams + pacing, ~15s)..."
    bw=$(probe_bandwidth "$peer" "$(detect_iface)") || die "bandwidth probe failed" 2
    ok "Measured ~${bw} Mbps"
  fi
  cmd_tune --role "$role" --bw "$bw" || die "base tuning failed"

  # 这四个必须在所有分支之前声明. set -u 下, 只要有一条路径没赋值,
  # 结尾传给 wizard_result 时就是 unbound variable —— v0.3.8 的"未检测到限速器"
  # 和"填 0 不整形"两条路都踩了这个(GitHub #1 #2).
  local knee="" rate="" margin="" no_knee=""

  # 手动指定了限速值（或选了不整形）→ 路径验证和拐点扫描都没有意义, 直接跳到应用
  if [ -n "$MANUAL_RATE" ]; then
    printf '\n  %s[2/3] Apply shaping%s\n' "$bold" "$plain"
    if [ "$MANUAL_RATE" = off ]; then
      cmd_shape --off
      rate=""
    else
      cmd_shape --rate "$MANUAL_RATE"
      rate="$MANUAL_RATE"
    fi
    printf '\n  %s[3/3] Verify%s\n' "$bold" "$plain"
    command -v iperf3 >/dev/null && verify_measure "$peer" || warn "no iperf3, throughput not verified"
    wizard_result "$bw" "$rate" "$knee" "$margin" "$ram"
    return 0
  fi

  printf '\n  %s[2/5] Path quality check%s\n' "$bold" "$plain"
  info "Probing at 40% of ${bw} Mbps -- far below any policer."
  echo "    Retransmits at this rate would mean the link itself is lossy."
  local v; v=$(validate_peer "$peer" "$bw" "$(detect_iface)")
  case "$v" in
    clean:*) ok "Path clean (retrans ${v#clean:})" ;;
    # 链路本身丢包只会让拐点读低一点, 数据仍然有效 —— 警告后照跑, 不打断
    dirty:*) warn "Link is lossy (retrans ${v#dirty:}). The knee may read low; sweep continues." ;;
    slow:*)  warn "Peer only reached ${v#slow:} Mbps. Sweep will decide whether to abort." ;;
    *)       warn "Path check failed; continuing anyway." ;;
  esac

  printf '\n  %s[3/5] Policer sweep%s\n' "$bold" "$plain"
  local sweep_rc=0
  cmd_sweep --peer "$peer" --nominal "$bw" || sweep_rc=$?
  # rc=3 是"扫完了但没有可用拐点"(没限速器/超上限/超范围), 结果文件是这轮写的, 可以读.
  # 其他非 0 是这轮压根没跑成, 结果文件已被清空, 不要去读.
  [ "$sweep_rc" = 0 ] || [ "$sweep_rc" = 3 ] || warn "sweep failed, shaping skipped"

  local out_of_range=""
  if { [ "$sweep_rc" = 0 ] || [ "$sweep_rc" = 3 ]; } && [ -f "$STATE_DIR/sweep.result" ]; then
    no_knee=$(awk -F= '/^NO_KNEE/{print $2}' "$STATE_DIR/sweep.result")
    out_of_range=$(awk -F= '/^OUT_OF_RANGE/{print $2}' "$STATE_DIR/sweep.result")
    knee=$(awk -F= '/^KNEE/{print $2}'      "$STATE_DIR/sweep.result")
    rate=$(awk -F= '/^RECOMMEND/{print $2}' "$STATE_DIR/sweep.result")
    [ -n "$knee" ] && [ -n "$rate" ] && margin=$(( knee - rate ))
  fi

  printf '\n  %s[4/5] Apply shaping%s\n' "$bold" "$plain"
  if [ -n "$rate" ]; then cmd_shape --rate "$rate"
  elif [ -n "$out_of_range" ]; then info "policer present but knee not located in range, shaping skipped"
  elif [ -n "$no_knee" ]; then info "no policer detected, shaping intentionally skipped"
  else warn "no knee measured, shaping skipped"; fi

  printf '\n  %s[5/5] Verify%s\n' "$bold" "$plain"
  command -v iperf3 >/dev/null && verify_measure "$peer" || warn "no iperf3, throughput not verified"

  wizard_result "$bw" "$rate" "$knee" "$margin" "$ram" "$no_knee" "$out_of_range"
}

# 结果段落. 正常流程和"手动指定整形值"两条路径共用, 避免两份重复的排版代码.
wizard_result(){   # wizard_result <带宽> <整形值> <拐点> <余量> <内存MB> [无拐点]
  local bw="${1:-}" rate="${2:-}" knee="${3:-}" margin="${4:-}" ram="${5:-0}" no_knee="${6:-}" oor="${7:-}"
  printf '\n  %s════ 结果 ══════════════════════════════════════════════%s\n' "$bold" "$plain"
  echo
  if [ -n "$knee" ]; then
    _conf "实测端口上限" "${knee} Mbit"
    _conf "安全余量"     "${margin} Mbit（按 ${bw}M 档位）"
    _conf "已应用整形"   "${rate} Mbit"
    echo
  elif [ -n "$rate" ]; then
    _conf "已应用整形"   "${rate} Mbit"
    echo
  elif [ -n "$oor" ]; then
    _conf "整形"         "未设置"
    _conf "原因"         "检测到限速迹象, 但未在扫描范围内定位到拐点"
    echo
  elif [ -n "$no_knee" ]; then
    _conf "整形"         "未设置"
    _conf "原因"         "扫描未发现限速器, 加整形只会限制自己"
    echo
  else
    _conf "整形"         "未设置"
    echo
  fi
  verify_verdict "$rate"
  traffic_report
  echo
  echo "  本次改动和快照位置"
  echo "      $SYSCTL_FILE"
  [ -n "$rate" ] && echo "      $QDISC_UNIT"
  echo "      $SNAPSHOT"

  # 小内存且没 swap 才提. 内存够用或已有 swap 就完全不出现这一段.
  if [ "$ram" -le 1024 ] && ! swapon --show 2>/dev/null | grep -q .; then
    step "swap"
    echo
    echo "    本机 ${ram} MB 内存且没有 swap. 跑代理时 TCP 缓冲区可能撑爆内存,"
    echo "    代理进程被系统杀掉."
    echo
    echo "    输入 1-20 的数字（单位 GB）, 推荐 1-4；回车 = 2；输入 0 = 不创建."
    echo
    # 这里必须自己校验. 直接把输入丢给 cmd_harden 的话, 非法值会触发它的 die,
    # 整个脚本跟着退出, 连"调优完成"都打不出来 —— v0.4.3 就是这么挂的.
    local sg
    while true; do
      sg=$(ask "  swap 大小 GB" "2")
      [ "$sg" = 0 ] && break
      if is_posint "${sg%[Gg]}" 1 20; then cmd_harden --swap "$sg"; break; fi
      warn "  请输入 1-20 之间的整数, 或 0 跳过"
    done
  fi
  echo
  ok "调优完成."
}

menu_loop(){
  need_root
  take_lock
  migrate_legacy
  self_install
  while true; do
    banner
    echo
    local c; c=$(ask "  请选择 / Select [0-8]" "1")
    echo
    case "$c" in
      1) wizard ;;
      2) local r; r=$(ask "  用途 1) 代理/加速  2) 大文件传输" "1")
         local role=proxy; [ "$r" = 2 ] && role=bulk
         local b; b=$(ask "  带宽 Mbps (回车=自动探测)" "")
         if [ -n "$b" ]; then cmd_tune --role "$role" --bw "$b"
         else
           local p; if p=$(auto_pick_peer); then PEER_PORT="${p##*:}"; cmd_tune --role "$role" --bw auto --peer "${p%:*}"
           else warn "No peer available; specify bandwidth manually"; fi
         fi ;;
      3) local p; if p=$(auto_pick_peer); then
           PEER_PORT="${p##*:}"; p="${p%:*}"
           local b; b=$(ask "  带宽 Mbps" "")
           cmd_sweep --peer "$p" --nominal "$b"
           local rate; rate=$(awk -F= '/^RECOMMEND/{print $2}' "$STATE_DIR/sweep.result" 2>/dev/null)
           [ -n "$rate" ] && confirm "  应用 ${rate}Mbit 整形？" y && cmd_shape --rate "$rate"
         else warn "No peer available"; fi ;;
      4) if swapon --show 2>/dev/null | grep -q .; then
           info "已有 swap: $(free -h | awk '/Swap/{print $2}'), 回车跳过；要再建就输入数字"
           local sg; sg=$(ask "  swap 大小 GB (1-20, 回车跳过)" ""); [ -n "$sg" ] && cmd_harden --swap "$sg"
         else
           echo "  输入 1-20 的数字（单位 GB）, 推荐 1-4；回车 = 2；输入 0 = 不创建."
           local sg; sg=$(ask "  swap 大小 GB" "2"); [ "$sg" != 0 ] && cmd_harden --swap "$sg"
         fi ;;
      5) cmd_status ;;
      6) local p; if p=$(auto_pick_peer); then PEER_PORT="${p##*:}"; cmd_verify --peer "${p%:*}"; else cmd_verify; fi ;;
      7) confirm "  确定回滚全部改动？" && cmd_rollback ;;
      8) cmd_update --from-menu ;;
      0) exit 0 ;;
      *) warn "Invalid selection" ;;
    esac
    echo
    printf "  ${yellow}按任意键返回${plain}"
    read -rsn1 </dev/tty 2>/dev/null || read -r </dev/tty 2>/dev/null || true
    echo
  done
}

# ── 入口 ────────────────────────────────────────────────────────────────────
usage(){ sed -n '2,20p' "$0" | sed 's/^# \?//'; }

case "${1:-}" in
  detect)   shift; cmd_detect "$@" ;;
  tune)     shift; cmd_tune "$@" ;;
  probe)    shift; cmd_probe "$@" ;;
  sweep)    shift; cmd_sweep "$@" ;;
  shape)    shift; cmd_shape "$@" ;;
  harden)   shift; cmd_harden "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  status)   shift; cmd_status "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  update)   shift; cmd_update "$@" ;;
  version)  echo "tcpfit $VERSION" ;;
  menu)     shift; menu_loop ;;
  "")       menu_loop ;;
  -h|--help|help) usage ;;
  *) die "未知命令: $1（-h 看用法）" ;;
esac
