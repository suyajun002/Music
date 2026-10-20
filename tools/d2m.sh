#!/usr/bin/env bash
#
# d2m.sh —— douyin2mp3 的构建 / 安装 / 启动 / 截图 一条龙。
#
# 为什么要有这个脚本：这些命令以前散在 SKILL.md 的散文里，每次都要照着抄一遍，
# 抄漏一个参数（比如 `D2M_APP_ID`、`DEVELOPMENT_TEAM`）就得到一个签名不对、
# 装不上的包，而报错现场离真正的原因很远。
#
# ★ 个人值不进仓库：团队 ID / bundle id / 设备 ID 从**环境变量或配置文件**读，
#   脚本里只有占位默认值。放到 ~/.config/d2m/env 就行（见下面「配置」）。
#
# 用法：
#   tools/d2m.sh build               编译（本机签好名）
#   tools/d2m.sh install             装到真机
#   tools/d2m.sh launch              启动
#   tools/d2m.sh deploy              = build + install + launch（最常用）
#   tools/d2m.sh devices             两台机器各自能看到哪些设备
#   tools/d2m.sh logs [K=V ...]      启动并挂控制台看日志（默认带 D2M_DEBUG=1）
#   tools/d2m.sh shot <输出路径>      截真机屏幕
#   tools/d2m.sh clean               删掉 build 目录
#
#   安装默认**自动挑路径**：本机能直接看到设备就走本机，看不到就走远端 Mac mini
#   （远端只当「USB 线」用，见下）。想强制就加 --local / --remote。
#
# 为什么会有「远端」这条路：
#   这台 Mac 上签名证书齐全（DEVELOPMENT_TEAM 在本机钥匙串里），但**手机并不是
#   总连在本机上**；而 [mini] 那台机器能看到手机、钥匙串里却没有本项目的证书。
#   两边各缺一半，所以做法是「本机编译 → rsync 过去 → 远端只执行 devicectl 安装」。
#   参考实现：~/.agents/skills/tv-video-skill/scripts/deploy-remote.sh
#
# 配置（按优先级：命令行环境变量 > ~/.config/d2m/env > 这里的默认值）
#   D2M_TEAM       Apple 开发者团队 ID（构建必需）。查法：
#                    security find-certificate -c "Apple Development: <email>" -p \
#                      | openssl x509 -noout -subject | grep -o 'OU=[^,]*'
#   D2M_APP_ID     App 的 bundle id（默认 com.example.douyin2mp3）
#   D2M_DEVICE     本机直连时的设备 UDID（不设 = 自动挑第一台可用设备）
#   D2M_REMOTE     ssh 目标，如 <用户>@<mac-mini-ip>；留空 = 不走远端
#   D2M_REMOTE_DEVICE  远端那台机器上设备的 **CoreDevice UUID**（跟本机看到的
#                      UDID 不是一回事，别混用；`tools/d2m.sh devices` 会打出来）
#   D2M_REMOTE_DIR 远端放 .app 的目录（默认 ~/d2m-build）
#
# 常用环境变量开关（透传到 App 里，见 SKILL.md「真机诊断」）
#   D2M_DEBUG=1        打印 [d2m] 取流/下载细节
#   D2M_MODE_DEMO=1    跑一遍顺序/随机播放模式自检
#   D2M_JUMP_DEMO=1    跑一遍续播「切走再切回来」自检
#   D2M_PREVIEW_DEMO=1 跑一遍试听「按未保存区间放、到点停」自检
#   D2M_YT_URL=...     走一遍真实 Apify 链路（★ 花钱，跑之前先问用户）
#
#   这些是**在设备上**跑的，所以要写成 DEVICECTL_CHILD_<名字>，脚本帮你转：
#     tools/d2m.sh logs D2M_MODE_DEMO=1
#     tools/d2m.sh deploy D2M_DEBUG=1
#
# 退出码：0 成功；1 真失败；3 设备不可用（手机锁着 / 两台机器都看不到它）
#   —— 分开 3 是为了让调用方（人或 agent）能区分「要去解锁手机」和「代码有问题」，
#      别对着一条 4016 去查代码。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${REPO_ROOT}/ios/Douyin2MP3/Douyin2MP3.xcodeproj"
SCHEME="Douyin2MP3"
APP_NAME="Douyin2MP3"
DERIVED="${REPO_ROOT}/build"
APP_PATH="${DERIVED}/Build/Products/Debug-iphoneos/${APP_NAME}.app"

# 配置文件：个人值放这儿，不进仓库
if [[ -f "${HOME}/.config/d2m/env" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/.config/d2m/env"
fi

D2M_APP_ID="${D2M_APP_ID:-com.example.douyin2mp3}"
D2M_REMOTE="${D2M_REMOTE:-}"
D2M_REMOTE_DIR="${D2M_REMOTE_DIR:-~/d2m-build}"
SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
info() { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "${YEL}" "$*" "${OFF}" >&2; }
die()  { printf '%s%s%s\n' "${RED}" "$*" "${OFF}" >&2; exit "${2:-1}"; }
ok()   { printf '%s%s%s\n' "${GRN}" "$*" "${OFF}"; }

# 设备不可用是**最常见**的失败，而且原因基本只有一个（手机锁着/没连上），
# 单独一个退出码，别跟真正的构建错误混在一起。
DEVICE_UNAVAILABLE_EXIT=3

# ---------------------------------------------------------------- 设备

# 从 `devicectl list devices` 的输出里挖出设备标识（没有则空）。
#
# 判据是「**状态不是 unavailable**」，不是「状态是 available」。这条踩过两次：
#  1. `unavailable` 里含子串 `available` —— 只 grep 'available' 会把**锁着的**
#     设备判成可用，然后每条命令吃一条 4016。
#  2. 状态词不止 available / unavailable：实测还有 **`connected`**
#     （`苏亚军phone ... connected`）。只认 'available' 会把一台明明连着、
#     能装的设备当成不在，脚本报「没有可用设备」而手机其实好端端插着 —— 非常误导。
# 所以反过来写：**排除 unavailable**，其余一律当可用。真要连不上，后面那条命令
# 会自己报错，比在这里猜状态准。
#
# ⚠️ 标识有两种格式，都得出得来：
#   本机 UDID          <8位hex>-<16位hex>                  （一个连字符）
#   远端 CoreDevice ID <8位>-<4位>-<4位>-<4位>-<12位>       （标准 UUID 形状，四个连字符）
# 所以正则要允许连字符：`[0-9A-F-]{16,}`。
# ⚠️ 别用 `awk '{print $3}'` 取第 3 列 —— 表头下面那行**分隔线**（`-----`）也在
# 输出里，$3 是一串横杠，会被当成设备标识，报出来的"设备"就是一排减号。
extract_device_id() {
  awk 'NR>1' \
    | grep -v 'unavailable' \
    | sed -n 's/.*\([0-9A-F]\{8\}-[0-9A-F-]\{16,\}\).*/\1/p' \
    | head -1
}

# 本机 devicectl 看得到的设备（没有则空）
local_udid() {
  local list
  list="$(xcrun devicectl list devices 2>/dev/null)" || return 1
  if [[ -n "${D2M_DEVICE:-}" ]]; then
    printf '%s' "${list}" | grep -q "${D2M_DEVICE}" || return 1
    # ⚠️ 点名了也要看状态：设备出现在列表里**不等于能用**，unavailable 的
    # （锁着 / 没连上）照样列出来。不判的话会把它当可用设备返回，后面每条命令
    # 都吃一条 4016，而报错现场完全看不出真正原因是「手机没连上」。
    printf '%s\n' "${list}" | grep "${D2M_DEVICE}" | grep -vq 'unavailable' || return 1
    printf '%s\n' "${D2M_DEVICE}"
    return 0
  fi
  printf '%s\n' "${list}" | extract_device_id
}

# 远端 mini 看得到的 UDID/UUID（没有则空）
remote_udid() {
  [[ -n "${D2M_REMOTE}" ]] || return 1
  ssh "${SSH_OPTS[@]}" "${D2M_REMOTE}" 'xcrun devicectl list devices 2>/dev/null' 2>/dev/null \
    | extract_device_id
}

# 决定这次走哪条路，把结果写进全局（见下面 require_device 的注释）。
# 输出：local | remote | none
pick_route() {
  if [[ "${FORCE_REMOTE}" == "yes" ]]; then
    [[ -n "$(remote_udid)" ]] && { printf 'remote\n'; return; }
    printf 'none\n'; return
  fi
  if [[ "${FORCE_LOCAL}" == "yes" ]]; then
    [[ -n "$(local_udid)" ]] && { printf 'local\n'; return; }
    printf 'none\n'; return
  fi
  [[ -n "$(local_udid)" ]] && { printf 'local\n'; return; }
  [[ -n "$(remote_udid)" ]] && { printf 'remote\n'; return; }
  printf 'none\n'
}

# 要操作的设备 / 走哪条路。由 require_target 填。
DEVICE=""
ROUTE=""

# ⚠️ 结果写在全局 ${DEVICE}/${ROUTE} 里，**不是**用 $(require_target) 取返回值：
# 那种写法里 `exit` 是在**子 shell** 里跑的，退出不了本脚本 —— 上层拿到空字符串
# 接着往下走，最后死在一条莫名其妙的 devicectl 报错上（实测 error 1000
# "Name: " 空设备名），完全看不出真正原因是「手机锁着」。
require_target() {
  ROUTE="$(pick_route)"
  case "${ROUTE}" in
    local)
      DEVICE="$(local_udid)"
      ;;
    remote)
      # ⚠️ 远端那台机器上的标识是 CoreDevice UUID（2F8A1DC4-…），
      # 跟本机看到的 UDID（00008150-…）**不是同一个字符串**，两边不能混用。
      DEVICE="$(remote_udid)"
      info "${DIM}本机看不到设备，走远端：${D2M_REMOTE}${OFF}"
      ;;
    *)
      warn "没有可用的真机（本机和远端都没看到）。"
      warn "devicectl 只能操作「已解锁且已唤醒」的设备，且要有连接（USB 或同一 Wi-Fi）。"
      warn "请把手机解锁点亮、确认连上，然后再试 —— 这一步没有命令行能代劳，别反复重试。"
      warn "排查：tools/d2m.sh devices"
      exit "${DEVICE_UNAVAILABLE_EXIT}"
      ;;
  esac
  [[ -n "${DEVICE}" ]] || { warn "拿到了空设备标识，异常。"; exit "${DEVICE_UNAVAILABLE_EXIT}"; }
}

# ---------------------------------------------------------------- 构建

cmd_build() {
  [[ -n "${D2M_TEAM:-}" ]] || die "缺 D2M_TEAM（团队 ID）。设为环境变量或写进 ~/.config/d2m/env，见脚本开头注释。"
  [[ -d "${PROJECT}" ]] || die "工程不在：${PROJECT}"

  info "${DIM}编译 ${SCHEME}（team=${D2M_TEAM} app_id=${D2M_APP_ID}）${OFF}"
  local log
  log="$(mktemp)"
  # ⚠️ D2M_APP_ID 必须传：工程里是占位值 com.example.douyin2mp3。
  # ⚠️ DEVELOPMENT_TEAM 同理，是个人值，留在命令行、不写回仓库。
  if ! xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination 'generic/platform=iOS' \
      -configuration Debug \
      -allowProvisioningUpdates \
      -derivedDataPath "${DERIVED}" \
      DEVELOPMENT_TEAM="${D2M_TEAM}" \
      D2M_APP_ID="${D2M_APP_ID}" \
      build > "${log}" 2>&1; then
    warn "编译失败，错误行："
    grep -E "error:" "${log}" | head -20 >&2
    die "完整日志：${log}"
  fi
  grep -E '^\*\* BUILD' "${log}" | tail -1
  [[ -d "${APP_PATH}" ]] || die "编译报成功但产物不在：${APP_PATH}"
  ok "编译成功：${APP_PATH}"
  rm -f "${log}"
}

# ---------------------------------------------------------------- 安装

# ★ 安装会**终止正在运行的 App**。抖音那条下载是进程内的 URLSessionDownloadTask，
#   一装就断、得重下；YouTube 那条更贵 —— Apify 的 run 已经开出去就照收费，钱花了歌没拿到。
#   所以这里默认**停下来问一句**，不图快先装再说。
confirm_no_downloads() {
  local assume_yes="${1:-no}"
  [[ "${assume_yes}" == "yes" ]] && return 0
  if [[ ! -t 0 ]]; then
    die "非交互环境，无法确认是否有下载在跑。确认过了就加 --yes 再跑。"
  fi
  warn "安装会终止正在运行的 App。"
  warn "如果「转视频」页里有正在下载或等待中的任务，现在别装 —— 抖音那条要重下，"
  warn "YouTube 那条 Apify 已经计费、断了就白花（约 ¥0.5/首）。"
  read -r -p "确认没有下载在跑，继续安装？[y/N] " reply
  [[ "${reply}" == "y" || "${reply}" == "Y" ]] || { info "已取消。"; exit 0; }
}

# 一次 install 的实际调用。装在远端时把结果打回去。
run_install() {
  if [[ "${ROUTE}" == "remote" ]]; then
    ssh "${SSH_OPTS[@]}" "${D2M_REMOTE}" \
      "xcrun devicectl device install app --device ${DEVICE} ${D2M_REMOTE_DIR}/${APP_NAME}.app" 2>&1
  else
    xcrun devicectl device install app --device "${DEVICE}" "${APP_PATH}" 2>&1
  fi
}

cmd_install() {
  local assume_yes="no"
  [[ "${1:-}" == "--yes" ]] && assume_yes="yes"
  require_target
  [[ -d "${APP_PATH}" ]] || die "没有产物，先跑 tools/d2m.sh build"
  confirm_no_downloads "${assume_yes}"

  if [[ "${ROUTE}" == "remote" ]]; then
    info "${DIM}传到 ${D2M_REMOTE}:${D2M_REMOTE_DIR} …${OFF}"
    # --delete：远端只留这一份，别攒一堆旧包；那个目录是专用的，删掉不心疼
    rsync -az --delete "${APP_PATH}" "${D2M_REMOTE}:${D2M_REMOTE_DIR}/" \
      || die "rsync 失败（${D2M_REMOTE} 通不通？）"
  fi

  info "${DIM}安装到 ${ROUTE}/${DEVICE} …${OFF}"
  local out
  out="$(run_install)"

  # ⚠️ 必须**硬判**安装结果。别处挂过 `|| true`，设备掉线时报错被吞掉、
  # 脚本照样打「✓ 完成」，看上去像装成功了 —— 实际手机上还是旧版本。
  if ! printf '%s' "${out}" | grep -q "App installed"; then
    # 设备锁着/黑着是**唯一**无法自动恢复的情况，单独给退出码 3
    if printf '%s' "${out}" | grep -qE '4016|not, or could not be, unlocked|Locked'; then
      printf '%s\n' "${out}" >&2
      warn "设备锁着/黑着，装不进去（错误 4016）。请解锁点亮手机后重试。"
      exit "${DEVICE_UNAVAILABLE_EXIT}"
    fi

    # ⚠️ 其余的失败（4000 / "peer is no longer reachable" / 掉线）**先换另一条路再判死**。
    # 实测设备会在两台机器之间「闪现」：本机刚看到 available，下一条命令就
    # peer no longer reachable。这时候远端往往还连着 —— 直接判失败会让用户
    # 白等一轮编译，而换个路子就过去了。
    local other=""
    [[ "${ROUTE}" == "local" ]] && other="remote"
    [[ "${ROUTE}" == "remote" ]] && other="local"
    if [[ -n "${other}" ]] && [[ -n "$(if [[ "${other}" == "remote" ]]; then remote_udid; else local_udid; fi)" ]]; then
      warn "经 ${ROUTE} 安装失败，改走 ${other} 再试一次。"
      ROUTE="${other}"
      DEVICE="$(if [[ "${other}" == "remote" ]]; then remote_udid; else local_udid; fi)"
      if [[ "${ROUTE}" == "remote" ]]; then
        rsync -az --delete "${APP_PATH}" "${D2M_REMOTE}:${D2M_REMOTE_DIR}/" \
          || die "rsync 失败（${D2M_REMOTE} 通不通？）"
      fi
      out="$(run_install)"
      printf '%s\n' "${out}" | grep -E 'bundleID|App installed|error|ERROR|Error' || true
      if ! printf '%s' "${out}" | grep -q "App installed"; then
        printf '%s\n' "${out}" >&2
        die "换 ${ROUTE} 也没装上。"
      fi
      ok "已安装（经 ${ROUTE}）。"
      return 0
    fi

    printf '%s\n' "${out}" >&2
    die "安装失败（见上面输出）。"
  fi
  printf '%s\n' "${out}" | grep -E 'bundleID|App installed' || true
  ok "已安装。"
}

# ---------------------------------------------------------------- 启动

# 把 K=V 形式的 D2M_* 开关转成 DEVICECTL_CHILD_* 参数。
# 为什么：那些开关是**在设备上**给 App 读的，devicectl 只认带这个前缀的环境变量。
env_args() {
  local pair
  for pair in "$@"; do
    [[ "${pair}" == *=* ]] || continue
    printf 'DEVICECTL_CHILD_%s=%s\n' "${pair%%=*}" "${pair#*=}"
  done
}

run_launch() {
  local console="$1"; shift
  local envargs=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && envargs+=("${line}")
  done < <(env_args "$@")

  # --terminate-existing：装完不会自动重启，不带这个可能看到的是旧界面
  # ⚠️ 别漏 `devicectl`：少了它就成了 `xcrun device ...`，
  # 报的是 `unable to find utility "device"` —— 看着像 Xcode 装坏了，其实只是少一个词。
  local flags=(devicectl device process launch --terminate-existing --device "${DEVICE}" "${D2M_APP_ID}")
  local cflags=(devicectl device process launch --console --terminate-existing --device "${DEVICE}" "${D2M_APP_ID}")
  [[ "${console}" == "console" ]] && flags=("${cflags[@]}")

  if [[ "${ROUTE}" == "remote" ]]; then
    # 远端：把环境变量和命令拼成一条 ssh。用 env 传变量，避免引号地狱。
    local envstr=""
    local e
    for e in ${envargs[@]+"${envargs[@]}"}; do envstr+=" ${e}"; done
    # shellcheck disable=SC2086
    ssh "${SSH_OPTS[@]}" "${D2M_REMOTE}" "env${envstr} xcrun ${flags[*]}"
  else
    # ⚠️ bash 3.2（macOS 自带）配 `set -u` 时，**空数组**的 `"${envargs[@]}"` 会报
    # `@: unbound variable`。不能直接展开 —— 不带开关地启动是常规用法（`d2m.sh launch`）。
    # `${arr[@]+"${arr[@]}"}` 是那个老写法：有元素才展开。
    if [[ ${#envargs[@]} -gt 0 ]]; then
      env "${envargs[@]}" xcrun "${flags[@]}"
    else
      xcrun "${flags[@]}"
    fi
  fi
}

cmd_launch() {
  require_target
  info "${DIM}启动 ${D2M_APP_ID} $*${OFF}"
  run_launch plain "$@" 2>&1 | tail -5
}

# 挂在控制台上看日志。
# ⚠️ 必须 --console 才能看到 App 里 DouyinDebug.log 的输出。
# ⚠️ 这里会一直阻塞到进程退出；那些 D2M_* 自检开关就是配这里用的。
#    远端模式下 ssh 会一直挂着，Ctrl-C 断的是 ssh 这头，**手机上那个 App 会继续跑** ——
#    自检完记得再干净重启一次（`tools/d2m.sh launch`），别让自检参数留在手机上。
cmd_logs() {
  require_target
  info "${DIM}启动并挂控制台（Ctrl-C 退出）${OFF}"
  run_launch console D2M_DEBUG=1 "$@"
}

# ---------------------------------------------------------------- 截图

# ⚠️ 截图**不是** `devicectl` 干的 —— 它压根没有截图子命令。
# `xcrun devicectl --help` 只有 device / diagnose / list / manage 四层；
# 在 `device` 下面敲 `capture screenshot` 会得到
# `Error: Unknown option '--device'`（因为 `capture` 不存在，devicectl 把
# `--device` 当成了 `device` 这一层的选项）。
#
# 真做法是 pymobiledevice3 的 DVT 接口：`developer dvt screenshot <out>`。
# iOS 17+ 上它会自己退到 userspace tunnel（日志里会打一行 "Trying again over
# a no-root userspace tunnel"），不用手动开 tunneld。
#
# 这台 Mac 上**没装** pymobiledevice3（只有 mini 上有，装在系统 python3.9 的
# 用户级 site-packages 里，所以 `command -v pymobiledevice3` 找不到它 ——
# 想探测得用 `python3 -m pymobiledevice3 version`）。手机通常插在 mini 上，
# 所以截图基本都走远端。
PYMOB="python3 -m pymobiledevice3"

# 过滤 pymobiledevice3 的名场面噪声（urllib3 的 LibreSSL 警告 + tunnel 回退提示）
pymob_noise='NotOpenSSLWarning|warnings\.warn|Trying again over'

# PNG 是不是「一片纯色」。
#
# ⚠️ 这一步不能省：**手机锁屏/黑屏时 iOS 照样返回一张尺寸正常的 PNG**，
# 只是内容全白/全黑。不查的话「截到一片白」会被报成截图成功 —— 而人看图时
# 只会以为 App 白屏了，方向直接跑偏。判据是解压后的原始像素字节里
# 不同取值的个数：真实界面有几百种，纯色图只有个位数。
png_is_blank() {
  python3 - "$1" <<'PYEOF'
import sys, zlib, struct
try:
    d = open(sys.argv[1], "rb").read()
except OSError:
    print("error"); sys.exit(0)
if d[:8] != b"\x89PNG\r\n\x1a\n":
    print("notpng"); sys.exit(0)
i, idat = 8, b""
while i + 8 <= len(d):
    ln = struct.unpack(">I", d[i:i + 4])[0]
    typ = d[i + 4:i + 8]
    if typ == b"IDAT":
        idat += d[i + 8:i + 8 + ln]
    if typ == b"IEND":
        break
    i += 12 + ln
try:
    raw = zlib.decompress(idat)
except zlib.error:
    print("error"); sys.exit(0)
print("blank" if len(set(raw)) <= 4 else "content")
PYEOF
}

cmd_shot() {
  local out="${1:-/tmp/d2m-shot.png}"
  require_target
  local tmp err size verdict
  if [[ "${ROUTE}" == "remote" ]]; then
    # 远端先截到它自己的 /tmp，再拉回来
    tmp="/tmp/d2m-shot-$$.png"
    err="$(ssh "${SSH_OPTS[@]}" "${D2M_REMOTE}" \
      "cd /tmp && ${PYMOB} developer dvt screenshot ${tmp} 2>&1" 2>&1 \
      | grep -viE "${pymob_noise}")"
    # 把 pymobiledevice3 的原话带出来，别自己编一个原因
    ssh "${SSH_OPTS[@]}" "${D2M_REMOTE}" "test -s ${tmp}" 2>/dev/null \
      || die "截图没生成（远端 ${D2M_REMOTE}）。pymobiledevice3 说：${err:-（没有输出，可能没装：python3 -m pymobiledevice3 version）}"
    scp "${SSH_OPTS[@]}" "${D2M_REMOTE}:${tmp}" "${out}" >/dev/null 2>&1 || die "取回截图失败"
    ssh "${SSH_OPTS[@]}" "${D2M_REMOTE}" "rm -f ${tmp}" >/dev/null 2>&1 || true
  else
    err="$(${PYMOB} developer dvt screenshot "${out}" 2>&1 | grep -viE "${pymob_noise}")"
    [[ -s "${out}" ]] || die "截图没生成（本机）。pymobiledevice3 说：${err:-（没有输出，可能没装：pip3 install --user pymobiledevice3）}"
  fi

  verdict="$(png_is_blank "${out}")"
  size="$(du -h "${out}" | cut -f1 | tr -d ' ')"
  if [[ "${verdict}" == "blank" ]]; then
    warn "截图是一张**纯色图**（${size}）—— 手机多半锁着/黑屏。"
    warn "解锁、让屏幕亮着，再截一次。文件留在 ${out} 供你确认。"
    return 0
  fi
  ok "截图：${out}（${size}）"
}

# ---------------------------------------------------------------- 其它

cmd_devices() {
  info "${DIM}── 本机 ${OFF}"
  xcrun devicectl list devices 2>&1
  if [[ -n "${D2M_REMOTE}" ]]; then
    info ""
    info "${DIM}── 远端 ${D2M_REMOTE}（安装走这里，当 USB 线用）${OFF}"
    ssh "${SSH_OPTS[@]}" "${D2M_REMOTE}" 'xcrun devicectl list devices 2>&1' 2>&1 \
      || warn "连不上 ${D2M_REMOTE}"
  else
    info ""
    info "${DIM}（未配 D2M_REMOTE，只看本机）${OFF}"
  fi
  info ""
  case "$(pick_route)" in
    local)  ok  "本次会走本机：$(local_udid)" ;;
    remote) ok  "本次会走远端：$(remote_udid)（经 ${D2M_REMOTE}）" ;;
    *)      warn "两台机器都没有可用设备。把手机解锁点亮、确认连上。" ;;
  esac
  info ""
  info "${DIM}注意：本机和远端看到的设备标识**不是同一个字符串**"
  info "本机是 UDID（00008150-…），远端是 CoreDevice UUID（2F8A1DC4-…）。别混用。${OFF}"
}

cmd_deploy() {
  local assume_yes="no"
  local args=()
  local a
  for a in "$@"; do
    case "${a}" in
      --yes)        assume_yes="yes" ;;
      --local)      FORCE_LOCAL="yes" ;;
      --remote)     FORCE_REMOTE="yes" ;;
      *)            args+=("${a}") ;;
    esac
  done
  cmd_build
  if [[ "${assume_yes}" == "yes" ]]; then cmd_install --yes; else cmd_install; fi
  # 装完必须启动一次才算「装完能跑」；--terminate-existing 保证看到的是新界面
  # ⚠️ 空数组在 bash 3.2 + set -u 下不能直接展开（同 run_launch 那条注释）
  if [[ ${#args[@]} -gt 0 ]]; then
    cmd_launch "${args[@]}"
  else
    cmd_launch
  fi
  ok "部署完成。"
}

cmd_clean() {
  rm -rf "${DERIVED}"
  ok "已删 ${DERIVED}"
}

usage() {
  sed -n '3,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- 入口

FORCE_LOCAL="no"
FORCE_REMOTE="no"

# 支持 --local/--remote 出现在子命令前面或后面（两种写法都有人用）；
# 先扫一遍摘掉，剩下的才是子命令自己的参数。
ARGS=()
for a in "$@"; do
  case "${a}" in
    --local)  FORCE_LOCAL="yes" ;;
    --remote) FORCE_REMOTE="yes" ;;
    *)        ARGS+=("${a}") ;;
  esac
done
# ⚠️ `${ARGS[@]:-}` 在 `${ARGS}` 为空时会展开成一个空字符串参数，bash 5 下还报
# "@: unbound variable"（`set -u` 对空数组的 `[@]` 也生效）。判一下长度再设。
if [[ ${#ARGS[@]} -gt 0 ]]; then
  set -- "${ARGS[@]}"
else
  set --
fi

case "${1:-}" in
  build)   shift; cmd_build "$@" ;;
  install) shift; cmd_install "$@" ;;
  launch)  shift; cmd_launch "$@" ;;
  deploy)  shift; cmd_deploy "$@" ;;
  logs)    shift; cmd_logs "$@" ;;
  shot)    shift; cmd_shot "$@" ;;
  devices) shift; cmd_devices "$@" ;;
  clean)   shift; cmd_clean "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "不认识的子命令：${1}（跑 tools/d2m.sh --help）" ;;
esac