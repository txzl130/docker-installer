#!/usr/bin/env bash
# docker-installer —— 一条命令把私有 compose 项目装到服务器上（支持升级 / 多选）
# 仓库：https://github.com/txzl130/docker-installer
#
# 用法：
#   curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/txzl130/docker-installer/main/install.sh -o /tmp/i.sh
#   sudo bash /tmp/i.sh                 # 不带参数 → 先问目录，再列编号选工具（可多选）
#   sudo bash /tmp/i.sh 1               # 按编号装（编号见 --list）
#   sudo bash /tmp/i.sh emby-proxy-manager
#   sudo bash /tmp/i.sh 1 2 --dir /opt/ysf/docker   # 装到统一根目录
#
# 参数：
#   --list              列出所有可安装的项目（带编号）
#   --dir <路径>        统一安装根目录（每个项目装到 <路径>/<项目名>；默认 /opt/ysf/docker）
#   --upgrade           升级已安装的目录（默认行为：目录里已有 docker-compose.yml 时自动升级）
#   --reinstall         重新安装：整个目录先备份成 .bak，再按全新安装（数据也会被带走）
#   --force             --reinstall 的别名
#   --clean-src         装好后删掉源码文件（只留镜像、data/、proxies/，之后不能再重建）
#   -u, --uninstall     卸载：停止并删除容器、镜像和整个目录（含 data/ 数据、证书、密码）
#   -y, --yes           删除/覆盖类操作不再询问（配合 --uninstall 的非交互使用）
#   --dry-run           只下载/校验/解密/解压，不构建也不启动
#   --no-start          只构建镜像，不启动容器
#   --password-stdin    从标准输入读密码（不推荐，优先交互输入）
#   -v, --verbose       显示下载源等细节（默认只显示友好进度）
#   --base <URL>        只用指定的安装器来源（默认按 ghfast → raw → gh-proxy → jsDelivr 依次尝试）
#   -h, --help          帮助
#
# 环境变量：
#   INSTALLER_BASE      安装器根地址；也可指向本地目录做测试，例如 file:///tmp/inst
#   INSTALLER_PASSWORD  安装密码（免交互）
#   INSTALLER_PBKDF2_ITER  解密迭代次数，默认 600000（必须与打包时一致）
#   UI_PORT / HEALTH_PORT  覆盖项目默认端口（9000、8080 被占用时最常用）
set -euo pipefail

VERSION="1.4.2"
# 安装器根地址：显式指定（--base / INSTALLER_BASE）时只用它；
# 否则按下面的镜像列表依次尝试 —— 国内直连 raw.githubusercontent.com 经常拉不动。
# ⚠️ jsDelivr 必须放最后：它的 @main 缓存可能长期返回旧版本，
#    而且「旧 project.conf + 旧加密包」是自洽的，校验和能对上，会静默装成旧版。
BASE="${INSTALLER_BASE:-}"
MIRRORS=(
  "https://ghfast.top/https://raw.githubusercontent.com/txzl130/docker-installer/main"
  "https://raw.githubusercontent.com/txzl130/docker-installer/main"
  "https://gh-proxy.com/https://raw.githubusercontent.com/txzl130/docker-installer/main"
  "https://cdn.jsdelivr.net/gh/txzl130/docker-installer@main"
)
ITER="${INSTALLER_PBKDF2_ITER:-600000}"

c_reset=""; c_red=""; c_grn=""; c_yel=""; c_dim=""
if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'
fi
info() { printf '%s==>%s %s\n' "$c_dim" "$c_reset" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
die()  { printf '%s[xx]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

usage() { awk 'NR==1{next} /^set -euo/{exit} {sub(/^# ?/,""); print}' "$0"; }

PROJECT=""; ROOT_DIR=""; TARGET_DIR=""; CLEAN_SRC=0; DRY_RUN=0; LIST=0; PW_STDIN=0; NO_START=0
UNINSTALL=0; ASSUME_YES=0; VERBOSE=0
MODE=""          # fresh / upgrade / reinstall（空 = 自动判断）
DIR_GIVEN=0
PROJECTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --list)           LIST=1; shift ;;
    --dir)            ROOT_DIR="${2:-}"; [ -n "$ROOT_DIR" ] || die "--dir 需要一个路径"; DIR_GIVEN=1; shift 2 ;;
    --upgrade)        MODE="upgrade"; shift ;;
    --reinstall)      MODE="reinstall"; shift ;;
    --force)          MODE="reinstall"; shift ;;
    --clean-src)      CLEAN_SRC=1; shift ;;
    -u|--uninstall)   UNINSTALL=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --no-start)       NO_START=1; shift ;;
    --password-stdin) PW_STDIN=1; shift ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    --base)           BASE="${2:-}"; [ -n "$BASE" ] || die "--base 需要一个地址"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    --version)        echo "docker-installer $VERSION"; exit 0 ;;
    -*)               die "未知参数：$1（用 --help 看用法）" ;;
    *)                PROJECTS+=("$1"); shift ;;
  esac
done

# 全程留一份日志，出问题时让用户直接发这个文件
if [ -z "${DI_LOG:-}" ]; then
  DI_LOG="/tmp/docker-installer-$(date +%Y%m%d-%H%M%S).log"
  export DI_LOG
  exec > >(tee -a "$DI_LOG") 2>&1
fi

fetch_one() { # $1 = 完整源地址，$2 = 输出文件
  local src="$1" out="$2" u
  case "$src" in
    http://*|https://*)
      # 加时间戳绕开 CDN 缓存（jsDelivr / ghfast 会长期返回旧文件，
      # 而我们按内容 sha256 校验，多一次请求比静默装旧版划算）
      case "$src" in
        *\?*) u="$src" ;;
        *)    u="$src?nocache=$(date +%s)-$$" ;;
      esac
      # 单个源最多等 120 秒：raw 在国内经常「连上了但一个字节也不给」
      curl -fsSL --connect-timeout 10 --max-time 120 \
        --speed-limit 512 --speed-time 40 "$u" -o "$out" ;;
    file://*)           cp -- "${src#file://}" "$out" ;;
    /*)                 cp -- "$src" "$out" ;;
    *)                  cp -- "$src" "$out" ;;
  esac
}

fetch() { # $1 = 项目内相对路径，$2 = 输出文件；成功后把可用源记到 BASE
  local rel="$1" out="$2" base
  if [ -n "$BASE" ]; then
    fetch_one "$BASE/$rel" "$out"
    return $?
  fi
  for base in "${MIRRORS[@]}"; do
    if fetch_one "$base/$rel" "$out"; then BASE="$base"; [ "$VERBOSE" = 1 ] && ok "下载源：$base"; return 0; fi
    [ "$VERBOSE" = 1 ] && warn "这个源拉不动，换下一个：$base"
  done
  return 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# 装 Docker（只在没装、且用户同意时走这里）
ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    docker compose version >/dev/null 2>&1 || die "docker compose 不可用（需要 Compose v2，运行 docker compose version 看看）"
    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') 已就绪"
    return 0
  fi
  warn "这台机器还没装 Docker（compose 版安装必须要有它）"
  if [ -z "$TTY_FD" ]; then
    die "请先装 Docker，再重新运行：
  curl -fsSL https://get.docker.com | sh        # 官方脚本
  # 国内慢就加镜像：curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun"
  fi
  ask "要现在自动安装 Docker 吗？(y/N)" "n"
  case "$REPLY" in
    y|Y|yes|YES) ;;
    *) die "已取消。装好 Docker 后重新运行本脚本即可（data/.env 都不会动）。" ;;
  esac
  [ "$(id -u)" = 0 ] || die "自动安装需要 root 权限（试试 sudo -i 后再运行）"
  info "下载 Docker 官方安装脚本"
  curl -fsSL --max-time 120 https://get.docker.com -o "$tmp/get-docker.sh" \
    || die "下载 get.docker.com 失败，请手动安装 Docker 后重试"
  info "开始安装 Docker（约 1～3 分钟）"
  if ! sh "$tmp/get-docker.sh"; then
    warn "默认源安装失败，改用阿里云镜像重试"
    sh "$tmp/get-docker.sh" --mirror Aliyun || die "Docker 安装失败，请看上面的报错"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 || die "装完仍找不到 docker 命令，请重新登录 shell 后再试"
  docker compose version >/dev/null 2>&1 || die "Docker 装好了，但缺少 compose 插件（apt install docker-compose-plugin）"
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') 安装完成"
}

port_busy() { # $1 = 端口；被占用返回 0
  # 升级/重装时，旧容器自己占着这个端口不算冲突（bash 是动态作用域，能读到调用方的 CONTAINER）
  if [ -n "${CONTAINER:-}" ] && command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "^${CONTAINER} .*:$1->"; then
      return 1
    fi
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1\$"
  else
    netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "[:.]$1\$"
  fi
}

port_owner() { # $1 = 端口 → 打印占用它的进程/容器（给人看，判断要不要停）
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E "[:.]$1 " | head -n3
  fi
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E ":$1->" | head -n3
  return 0
}

# ---------- 临时目录 ----------
need curl
tmp="$(mktemp -d)"; chmod 700 "$tmp"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

fetch_list() { fetch "projects/list.txt" "$tmp/list.txt" || die "拉不到项目列表（试过所有镜像），可用 --base 指定源"; }

print_list() {
  local i=0 n t d v
  printf '  %-3s %-24s %-8s %s\n' "编号" "项目" "版本" "说明"
  while IFS='|' read -r n t d v; do
    [ -n "${n:-}" ] || continue
    i=$((i + 1))
    printf '  %-3s %-24s %-8s %s\n' "$i" "$n" "${v:--}" "$t"
  done < "$tmp/list.txt"
}

# ---------- --list ----------
if [ "$LIST" = 1 ]; then
  fetch_list
  print_list
  exit 0
fi

# ---------- 交互能力检测 ----------
# 直接运行脚本：stdin 是终端，正常交互。
# 管道运行（curl ... | bash）：stdin 是脚本自身，但 /dev/tty 还在 → 所有提问走 /dev/tty。
# ⚠️ 注意：TTY_FD 只能是「路径」，绝不能是数字 0。
# 这里写成 0 会让 `printf > "$TTY_FD"` 变成 `> 0` —— 那会新建一个名叫 0 的文件，
# 提示语被写进文件、紧接着 `read < "$TTY_FD"` 又从那个文件读回来，
# 于是密码变成提示语、交互全部错乱（2026-11-08 在香港机上实测踩到）。
TTY_FD=""
if ( : >/dev/tty ) 2>/dev/null; then
  TTY_FD=/dev/tty
elif [ -t 0 ]; then
  TTY_FD=/dev/stdin
fi

ask() { # $1=提示 $2=默认值 → 结果在 REPLY（回车用默认值）
  local def="${2:-}" ans="" prompt="$1"
  [ -n "$def" ] && prompt="$prompt [$def]"
  if [ -n "$TTY_FD" ]; then
    printf '%s: ' "$prompt" >&2
    IFS= read -r ans < "$TTY_FD" || ans=""
  fi
  [ -n "$ans" ] || ans="$def"
  REPLY="$ans"
}

ask_secret() { # $1=提示 → 结果在 REPLY（不回显）
  local ans=""
  if [ -n "$TTY_FD" ]; then
    printf '%s' "$1" >&2
    IFS= read -rs ans < "$TTY_FD" || ans=""
    printf '\n' >&2
  fi
  REPLY="$ans"
}

# ---------- 统一安装根目录（先问，只问一次） ----------
if [ "$DIR_GIVEN" = 0 ] && [ -n "$TTY_FD" ] && [ "$UNINSTALL" = 0 ]; then
  echo
  ask "安装根目录（每个项目一个子目录，直接回车=不改）" "${ROOT_DIR:-/opt/ysf/docker}"
  ROOT_DIR="$REPLY"
fi
[ -n "$ROOT_DIR" ] || ROOT_DIR="/opt/ysf/docker"

# ---------- 这台机器上已经装过什么？先问你要装还是要卸 ----------
if [ -n "$TTY_FD" ] && [ "$UNINSTALL" = 0 ] && [ "${#PROJECTS[@]}" -eq 0 ] && [ -d "$ROOT_DIR" ]; then
  installed_list=()
  for d in "$ROOT_DIR"/*/; do
    [ -f "${d}docker-compose.yml" ] || continue
    installed_list+=("$(basename "$d")|$(head -n1 "${d}.installed-version" 2>/dev/null || echo '未知')")
  done
  if [ "${#installed_list[@]}" -gt 0 ]; then
    echo
    echo "这台机器上已经有："
    for it in "${installed_list[@]}"; do
      printf '  %-28s %s\n' "${it%%|*}" "版本 ${it##*|}"
    done
    ask "要做什么？1=安装/升级（默认）  2=卸载" "1"
    case "$REPLY" in
      2|u|U|uninstall) UNINSTALL=1 ;;
    esac
  fi
fi

# ---------- 选项目：编号，可多选 ----------
if [ "${#PROJECTS[@]}" -eq 0 ]; then
  fetch_list
  if [ "$UNINSTALL" = 1 ]; then echo "要卸载哪个项目？"; else echo "可安装的项目："; fi
  print_list
  echo
  if [ -z "$TTY_FD" ]; then
    die "非交互环境必须指定项目（编号或名字），例如：bash install.sh 1"
  fi
  count="$(grep -c . "$tmp/list.txt" || true)"
  if [ "$UNINSTALL" = 1 ]; then
    ask "输入要卸载的编号（可多选，空格或逗号分隔）" ""
    [ -n "$REPLY" ] || die "没选要卸载的项目"
  else
    ask "输入编号（可多选，空格或逗号分隔，直接回车=1）" "1"
  fi
  reply="${REPLY//,/ }"
  PROJECTS=()
  for tok in $reply; do
    case "$tok" in
      ''|*[!0-9]*) die "编号只能是数字：$tok" ;;
    esac
    if [ "$tok" -lt 1 ] || [ "$tok" -gt "$count" ]; then die "没有编号 $tok（可选 1～$count）"; fi
    PROJECTS+=("$(sed -n "${tok}p" "$tmp/list.txt" | cut -d'|' -f1)")
  done
fi

# 允许直接用编号（bash install.sh 1 2）
num_needed=0
if [ "${#PROJECTS[@]}" -gt 0 ]; then
  for x in "${PROJECTS[@]}"; do
    case "$x" in
      ''|*[!0-9]*) ;;
      *) num_needed=1 ;;
    esac
  done
fi
if [ "$num_needed" = 1 ]; then
  fetch_list
  count="$(grep -c . "$tmp/list.txt" || true)"
  NEWP=()
  for x in "${PROJECTS[@]}"; do
    case "$x" in
      ''|*[!0-9]*) NEWP+=("$x") ;;
      *)
        if [ "$x" -lt 1 ] || [ "$x" -gt "$count" ]; then die "没有编号 $x（可选 1～$count）"; fi
        NEWP+=("$(sed -n "${x}p" "$tmp/list.txt" | cut -d'|' -f1)") ;;
    esac
  done
  PROJECTS=("${NEWP[@]}")
fi
[ "${#PROJECTS[@]}" -gt 0 ] || die "没选项目"

# ---------- 卸载模式（--uninstall） ----------
uninstall_one() {
  local proj="$1" dir name="" conf_tmp k v img="" ans leftover
  name="$proj"
  conf_tmp="$(mktemp)"
  if fetch "projects/$proj/project.conf" "$conf_tmp" 2>/dev/null; then
    while IFS='=' read -r k v; do
      case "$k" in NAME) [ -n "$v" ] && name="$v" ;; esac
    done < "$conf_tmp"
  fi
  rm -f "$conf_tmp"
  dir="$ROOT_DIR/$name"
  case "$ROOT_DIR" in */"$name") dir="$ROOT_DIR" ;; esac

  info "卸载：$name"
  info "目录：$dir"
  if [ ! -d "$dir" ]; then
    warn "目录不存在，跳过：$dir"
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && [ -f "$dir/docker-compose.yml" ]; then
    img="$( cd "$dir" && docker compose config --images 2>/dev/null | head -n1 || true )"
    info "停止并删除容器"
    ( cd "$dir" && docker compose down --remove-orphans ) || warn "docker compose down 失败（继续删目录）"
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    if [ -z "$TTY_FD" ]; then
      die "非交互环境删除目录必须加 --yes（会连同 data/ 里的数据、证书、登录密码一起删掉）"
    fi
    printf '%s' "确定删除 $dir（含 data/ 数据、证书、登录密码）？(y/N) " >&2
    IFS= read -r ans < "$TTY_FD" || ans=""
    case "$ans" in
      y|Y|yes|YES) ;;
      *) die "已取消，什么都没删" ;;
    esac
  fi
  # 容器以 root 写的文件，普通用户 rm -rf 会 Permission denied → 用 busybox 容器兜底
  if ! rm -rf "$dir" 2>/dev/null || [ -d "$dir" ]; then
    rm -rf "$dir" 2>/dev/null || true
    if [ -d "$dir" ]; then
      warn "有的文件归 root（容器写的），改用 busybox 容器删"
      # 注意要挂父目录、删子目录：挂载点本身删不掉
      docker run --rm -v "$(dirname "$dir")":/x busybox rm -rf "/x/$(basename "$dir")" >/dev/null 2>&1 || true
    fi
  fi
  if [ -d "$dir" ]; then
    warn "目录没删干净，请手工处理：sudo rm -rf '$dir'"
  else
    ok "已删除 $dir"
    # 升级/重装留下的备份（.code-*.tgz / .bak.*）不会自动删，列出来让用户自己决定
    leftover="$(ls -1d "$(dirname "$dir")/$(basename "$dir").code-"* "$(dirname "$dir")/$(basename "$dir").bak."* 2>/dev/null || true)"
    if [ -n "$leftover" ]; then
      warn "还留着备份（确认没问题后可删）："
      printf '%s\n' "$leftover" | sed 's/^/    /' >&2
    fi
    rmdir "$ROOT_DIR" 2>/dev/null || true   # 根目录空了就一起清掉
  fi
  if [ -n "$img" ]; then
    if docker rmi "$img" >/dev/null 2>&1; then ok "已删除镜像 $img"
    else warn "镜像没删掉（可能还被别的容器用着）：$img"; fi
  fi
}

if [ "$UNINSTALL" = 1 ]; then
  [ -n "$ROOT_DIR" ] || ROOT_DIR="/opt/ysf/docker"
  for pj in "${PROJECTS[@]}"; do
    uninstall_one "$pj"
    echo
  done
  ok "卸载完成"
  exit 0
fi

need openssl; need tar; need sha256sum

# ---------- 环境检查（只做一次） ----------
if [ "$DRY_RUN" = 0 ]; then ensure_docker; fi

# ---------- 密码（只问一次，所有项目共用一个） ----------
PW=""
if [ "$PW_STDIN" = 1 ]; then
  IFS= read -r PW || true
elif [ -n "${INSTALLER_PASSWORD:-}" ]; then
  PW="$INSTALLER_PASSWORD"
else
  [ -n "$TTY_FD" ] || die "没有终端，无法交互输入密码（可用 --password-stdin 从管道喂密码）"
  ask_secret '请输入安装密码（输入时看不到字符）：'
  PW="$REPLY"
fi
[ -n "$PW" ] || die "密码为空"

# ======================================================================
# 单个项目的安装流程
# ======================================================================
MOD_DEFAULT="$MODE"
MODE=""

install_one() {
  local PROJECT="$1"
  local NAME="" TITLE="" DIR_CONF="" PORTS="" ENV_FROM="" IMAGE="" CONTAINER=""
  local PKG="" PKG_SHA256="" TAR_SHA256="" NOTE="" PKG_VERSION=""
  local INSTALLED_VERSION="" IS_EXISTING MODE PORTS_DISPLAY probedir avail_k mem_kb swap_kb
  local got bak cbak busy eff_ports first p img status n reply

  info "项目：$PROJECT"
  info "正在下载安装包…"
  # project.conf 与安装包必须同源；而且各镜像的缓存新旧不一（jsDelivr / ghfast 都可能长期吃旧缓存）。
  # 危险的是「旧 conf + 旧包」本身是自洽的：校验和对得上，于是静默装成旧版本。
  # 所以先把所有源的 conf 都拉下来（带时间戳绕缓存），挑版本号最高的那个源，再用它装。
  local bases=() base fetched=0
  if [ -n "$BASE" ]; then bases=("$BASE"); else bases=("${MIRRORS[@]}"); fi
  local i=0 cands=() cver cbase sorted
  for base in "${bases[@]}"; do
    if fetch_one "$base/projects/$PROJECT/project.conf" "$tmp/conf.$i"; then
      cver="$(sed -n 's/^VERSION=//p' "$tmp/conf.$i" | head -n1 | tr -d '\r')"
      [ -n "$cver" ] || cver="0"
      cands+=("$cver|$i|$base")
    else
      [ "$VERBOSE" = 1 ] && warn "这个源拉不动，跳过：$base"
    fi
    i=$((i + 1))
  done
  [ "${#cands[@]}" -gt 0 ] || die "所有源都拿不到 $PROJECT 的 project.conf（可试试 --base 指定别的源）"
  sorted="$(printf '%s\n' "${cands[@]}" | sort -t'|' -k1,1Vr)"

  while IFS='|' read -r cver i cbase; do
    [ -n "$cbase" ] || continue
    cp -f "$tmp/conf.$i" "$tmp/project.conf"
    # 读取元数据（只认 KEY=VALUE，不执行里面的任何命令）
    NAME=""; TITLE=""; DIR_CONF=""; PORTS=""; ENV_FROM=""; IMAGE=""; CONTAINER=""
    PKG=""; PKG_SHA256=""; TAR_SHA256=""; NOTE=""; PKG_VERSION=""
    while IFS='=' read -r k v; do
      case "$k" in
        NAME) NAME="$v" ;; TITLE) TITLE="$v" ;; DIR) DIR_CONF="$v" ;; PORTS) PORTS="$v" ;;
        ENV_FROM) ENV_FROM="$v" ;; IMAGE) IMAGE="$v" ;; CONTAINER) CONTAINER="$v" ;;
        PKG) PKG="$v" ;; PKG_SHA256) PKG_SHA256="$v" ;; TAR_SHA256) TAR_SHA256="$v" ;; NOTE) NOTE="$v" ;;
        VERSION) PKG_VERSION="$v" ;;
      esac
    done < "$tmp/project.conf"
    [ -n "$PKG" ] || { warn "$cbase 上的 project.conf 不完整，跳过"; continue; }

    if ! fetch_one "$cbase/projects/$PROJECT/$PKG" "$tmp/pkg.enc"; then
      [ "$VERBOSE" = 1 ] && warn "这个源拿不到安装包，换下一个：$cbase"; continue
    fi
    if [ -n "$PKG_SHA256" ]; then
      got="$(sha256sum "$tmp/pkg.enc" | awk '{print $1}')"
      if [ "$got" != "$PKG_SHA256" ]; then
        [ "$VERBOSE" = 1 ] && warn "$cbase 的包和校验和不一致（缓存问题），换下一个源"
        continue
      fi
    fi
    BASE="$cbase"; [ "$VERBOSE" = 1 ] && ok "下载源：$cbase"; fetched=1; break
  done <<< "$sorted"
  [ "$fetched" = 1 ] || die "所有源都拿不到 $PROJECT 的可用安装包（多半是镜像还在缓存旧版本：等 1~2 分钟重跑，或加 --base 换一个源）"

  [ -n "$NAME" ] || NAME="$PROJECT"

  # 统一根目录 + 项目名；--dir 给的是根，不是最终目录
  TARGET_DIR="$ROOT_DIR/$NAME"
  # 兼容旧写法：--dir 直接指到了该项目目录（路径以项目名结尾）时，不再套一层
  case "$ROOT_DIR" in
    */"$NAME") TARGET_DIR="$ROOT_DIR" ;;
  esac

  # ---------- 判断是 新装 / 升级 / 重装 ----------
  INSTALLED_VERSION=""
  if [ -f "$TARGET_DIR/.installed-version" ]; then
    INSTALLED_VERSION="$(head -n1 "$TARGET_DIR/.installed-version" 2>/dev/null || true)"
  fi
  IS_EXISTING=0
  [ -f "$TARGET_DIR/docker-compose.yml" ] && IS_EXISTING=1

  MODE="$MOD_DEFAULT"
  if [ -z "$MODE" ]; then
    if [ "$IS_EXISTING" = 1 ]; then MODE="upgrade"; else MODE="fresh"; fi
  fi
  if [ "$MODE" = "upgrade" ] && [ "$IS_EXISTING" != 1 ]; then
    die "目录 $TARGET_DIR 里没有 docker-compose.yml，不能升级（要新装就去掉 --upgrade）"
  fi

  info "标题：${TITLE:-$NAME}"
  info "安装器版本：$VERSION"
  info "目录：$TARGET_DIR"
  [ -n "$PORTS" ] && info "端口：$PORTS"
  if [ "$MODE" = "upgrade" ]; then
    info "模式：升级 ${INSTALLED_VERSION:-（未知版本）} → ${PKG_VERSION:-（未知版本）}"
  elif [ "$MODE" = "reinstall" ]; then
    info "模式：重新安装（旧目录会备份成 .bak）"
  else
    info "模式：全新安装${PKG_VERSION:+（版本 $PKG_VERSION）}"
  fi

  # ---------- 磁盘检查 ----------
  if [ "$DRY_RUN" = 0 ]; then
    # 第一次安装时目标目录还不存在，先往上找到存在的目录再问 df（否则 df 报错会误报 0 MB）
    probedir="$TARGET_DIR"
    while [ ! -d "$probedir" ] && [ "$probedir" != "/" ]; do probedir="$(dirname "$probedir")"; done
    avail_k="$(df -Pk "$probedir" 2>/dev/null | awk 'NR==2{print $4}' || true)"
    if [ -n "${avail_k:-}" ] && [ "$avail_k" -ge 0 ] 2>/dev/null && [ "$avail_k" -lt 2097152 ]; then
      warn "目标磁盘（$probedir）只剩 $((avail_k / 1024)) MB，可能不够构建（建议至少 2 GB）"
    fi
    # 内存检查：小机器构建容易被 OOM 杀掉（2G 以下又没 swap 时最容易）
    mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)"
    swap_kb="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)"
    if [ -n "${mem_kb:-}" ] && [ "${mem_kb:-0}" -lt 1500000 ] 2>/dev/null && [ "${swap_kb:-0}" -eq 0 ] 2>/dev/null; then
      warn "内存只有 $((mem_kb / 1024)) MB 且没开 swap，构建可能很慢甚至失败（建议加 1~2G swap）"
    fi
  fi

  # ---------- 解密 ----------
  info "解密"
  local attempt=0 decrypted=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if printf '%s' "$PW" | openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" \
          -in "$tmp/pkg.enc" -out "$tmp/pkg.tar.gz" -pass stdin 2>/dev/null; then
      decrypted=1; break
    fi
    # 密码指纹对不上 = 这个包压根不是用这个密码加密的，重试没意义
    if [ -n "${PW_CHECK:-}" ] && [ "$(printf '%s' "$PW" | sha256sum | cut -c1-12)" != "$PW_CHECK" ]; then
      die "安装密码不对：这个安装包不是用这个密码加密的（发布时可能换了密码），请找维护者确认最新密码"
    fi
    # 只有「用户自己敲密码」时才有必要重试；环境变量/管道来的密码重试无意义
    if [ -n "$TTY_FD" ] && [ "$PW_STDIN" != 1 ] && [ -z "${INSTALLER_PASSWORD:-}" ]; then
      warn "密码不对（第 $attempt 次，共 3 次）"
      ask_secret '再输一次安装密码（输入时看不到字符）：'
      [ -n "$REPLY" ] || die "密码为空"
      PW="$REPLY"
    else
      die "解密失败：密码不对，或安装包损坏"
    fi
  done
  [ "$decrypted" = 1 ] || die "解密失败：密码不对，或安装包损坏"
  if [ -n "$TAR_SHA256" ]; then
    got="$(sha256sum "$tmp/pkg.tar.gz" | awk '{print $1}')"
    [ "$got" = "$TAR_SHA256" ] || die "解密后内容校验失败（安装包可能被替换）"
  fi
  ok "解密成功"

  # 先解到临时目录，确认是完整项目再动目标目录
  rm -rf "$tmp/new"; mkdir -p "$tmp/new"
  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp/new"
  [ -f "$tmp/new/docker-compose.yml" ] || die "安装包内容不对：里面没有 docker-compose.yml"

  if [ "$DRY_RUN" = 1 ]; then
    info "dry-run：不构建、不启动"
    echo "  安装包内容："
    ls -la "$tmp/new" | sed 's/^/    /'
    info "目标目录将变为：$TARGET_DIR（模式：$MODE）"
    return 0
  fi

  # ---------- 落盘 ----------
  if [ "$MODE" = "reinstall" ] && [ -d "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]; then
    bak="$TARGET_DIR.bak.$(date +%Y%m%d-%H%M%S)"
    info "重新安装：先把旧目录整体备份到 $bak"
    ( cd "$TARGET_DIR" && docker compose down --remove-orphans >/dev/null 2>&1 || true )
    mv "$TARGET_DIR" "$bak"
    ok "已备份（要回退：rm -rf '$TARGET_DIR' && mv '$bak' '$TARGET_DIR'）"
    MODE="fresh"
  fi

  if [ "$MODE" = "upgrade" ]; then
    # 1) 代码备份（不含 data/，缓存可能有几十 G）
    cbak="$(dirname "$TARGET_DIR")/$(basename "$TARGET_DIR").code-$(date +%Y%m%d-%H%M%S).tgz"
    info "升级：备份旧代码到 $cbak"
    tar -czf "$cbak" -C "$(dirname "$TARGET_DIR")" \
        --exclude="$(basename "$TARGET_DIR")/data" --exclude="$(basename "$TARGET_DIR")/.env" \
        "$(basename "$TARGET_DIR")" 2>/dev/null || warn "代码备份失败，继续"
    # 2) 停容器（释放端口，避免升级过程中一半新一半旧）
    info "升级：停止旧容器"
    ( cd "$TARGET_DIR" && docker compose down --remove-orphans ) || warn "旧容器停止失败，继续尝试"
    # 3) 覆盖代码（data/、proxies/、.env 不在包里，不会被覆盖）
    info "升级：替换代码（保留 data/、proxies/、.env）"
    tar -xzf "$tmp/pkg.tar.gz" -C "$TARGET_DIR"
    ok "代码已更新；回退可用：tar -xzf '$cbak' -C '$(dirname "$TARGET_DIR")'"
  else
    mkdir -p "$TARGET_DIR"
    tar -xzf "$tmp/pkg.tar.gz" -C "$TARGET_DIR"
    ok "已释放到 $TARGET_DIR"
  fi

  # ---------- .env ----------
  if [ -n "$ENV_FROM" ] && [ ! -f "$TARGET_DIR/.env" ] && [ -f "$TARGET_DIR/$ENV_FROM" ]; then
    cp "$TARGET_DIR/$ENV_FROM" "$TARGET_DIR/.env"
    ok "已生成 .env（来自 $ENV_FROM，可自行修改）"
  fi

  # ---------- 管理台是否对外开放 ----------
  # 项目默认 UI_BIND=127.0.0.1（安全，但外部打不开）；这里问一次，省得装完一脸问号
  BIND_LOOPBACK=0
  if [ -f "$TARGET_DIR/.env" ]; then
    cur_bind="$(grep -E '^UI_BIND=' "$TARGET_DIR/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    if [ "$cur_bind" = "127.0.0.1" ]; then
      want_open=0
      if [ -n "$TTY_FD" ] && [ "$ASSUME_YES" != 1 ] && [ "$MODE" != "upgrade" ]; then
        ask "管理台要不要允许公网访问（改成 0.0.0.0，走 http 明文；n = 只本机 + SSH 隧道）" "n"
        case "$REPLY" in y|Y|yes|YES) want_open=1 ;; esac
      fi
      if [ "$want_open" = 1 ]; then
        sed -i 's/^UI_BIND=.*/UI_BIND=0.0.0.0/' "$TARGET_DIR/.env"
        ok "管理台已允许公网访问（UI_BIND=0.0.0.0）"
      else
        BIND_LOOPBACK=1
        info "管理台只绑本机；外部访问请走 SSH 隧道：ssh -L 9000:127.0.0.1:9000 root@<服务器IP>"
      fi
    fi
  fi

  # ---------- 端口预检 ----------
  eff_ports=""
  if [ -n "$PORTS" ]; then
    first=1
    for p in ${PORTS//,/ }; do
      if [ "$first" = 1 ] && [ -n "${UI_PORT:-}" ]; then p="$UI_PORT"; fi
      first=0
      eff_ports="$eff_ports $p"
    done
  fi
  [ -n "${HEALTH_PORT:-}" ] && eff_ports="$eff_ports $HEALTH_PORT"

  busy=""
  for p in $eff_ports; do
    if port_busy "$p"; then busy="$busy $p"; fi
  done
  if [ -n "$busy" ]; then
    warn "这些端口已被别的程序占用：${busy}"
    echo "  占用情况：" >&2
    for p in $busy; do port_owner "$p" >&2; done
    die "处理办法（任选）：
    1) 空出端口：上面列出的进程/容器停掉
    2) 换个端口装：UI_PORT=19000 HEALTH_PORT=18080 bash install.sh $PROJECT
    3) 装完再改 $TARGET_DIR/.env，然后 docker compose up -d"
  fi
  ok "端口空闲：$eff_ports"

  # ---------- 构建 ----------
  info "构建镜像（首次约 1～2 分钟）"
  # Docker 29 起 build.network=host 需要显式授权，否则 compose build 会直接报
  # "additional privileges requested"（以前只能靠失败后回退）
  if ! ( cd "$TARGET_DIR" && BUILDX_ENTITLEMENTS=network.host docker compose build ); then
    warn "docker compose build 失败，改用 docker build --network host"
    img="$( cd "$TARGET_DIR" && docker compose config --images 2>/dev/null | head -n1 || true )"
    [ -n "$img" ] || img="${IMAGE:-$NAME:local}"
    ( cd "$TARGET_DIR" && docker build --network host -t "$img" . ) || die "构建失败（日志：$DI_LOG）"
    ok "已用 --network host 构建出 $img"
  fi

  if [ "$NO_START" = 1 ]; then
    ok "镜像已构建（--no-start，未启动容器）"
    echo "$PKG_VERSION" > "$TARGET_DIR/.installed-version"
    return 0
  fi

  # ---------- 启动 ----------
  info "启动容器"
  ( cd "$TARGET_DIR" && docker compose up -d --remove-orphans --no-build >/dev/null ) \
    || die "启动失败（日志：$DI_LOG）"

  # ---------- 等健康 ----------
  if [ -n "$CONTAINER" ]; then
    info "等待容器就绪"
    n=0; status=""
    while [ "$n" -lt 60 ]; do
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo missing)"
      case "$status" in
        healthy|running) break ;;
        missing) break ;;
      esac
      n=$((n + 1)); sleep 2
    done
    case "$status" in
      healthy|running) ok "容器状态：$status" ;;
      *) warn "容器状态：$status（继续，排查：docker logs --tail 50 $CONTAINER）"
         if [ -n "${cbak:-}" ]; then
           echo "  回退旧版本（一行）："
           echo "    tar -xzf '$cbak' -C '$(dirname "$TARGET_DIR")' && (cd '$TARGET_DIR' && docker compose up -d --force-recreate)"
         fi ;;
    esac
  fi

  # ---------- 记录版本 ----------
  echo "$PKG_VERSION" > "$TARGET_DIR/.installed-version" 2>/dev/null || true

  # ---------- 输出结果 ----------
  local ip ui_port pub
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ip" ] || ip="<本机IP>"
  # 云服务器大多是 NAT：hostname -I 给的是 10.x/172.x 内网地址，外面访问不到 → 问一次公网 IP
  case "$ip" in
    10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
      pub="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
      [ -n "$pub" ] && ip="$pub" ;;
  esac
  ui_port="${UI_PORT:-${PORTS%%,*}}"
  PORTS_DISPLAY="$PORTS"
  if [ -n "${UI_PORT:-}" ] && [ -n "$PORTS" ]; then
    local rest="${PORTS#*,}"
    if [ "$rest" = "$PORTS" ]; then PORTS_DISPLAY="$UI_PORT"; else PORTS_DISPLAY="$UI_PORT,$rest"; fi
  fi
  echo
  if [ "$MODE" = "upgrade" ]; then
    printf '%s升级完成%s\n' "$c_grn" "$c_reset"
    echo "  版本    ${INSTALLED_VERSION:-未记录} → ${PKG_VERSION:-未记录}"
  else
    printf '%s安装完成%s\n' "$c_grn" "$c_reset"
    [ -n "$PKG_VERSION" ] && echo "  版本    $PKG_VERSION"
  fi
  [ -n "$PORTS" ] && echo "  端口    $PORTS_DISPLAY"
  echo "  目录    $TARGET_DIR"

  # 密码是否已经设过：设过就不打印令牌（令牌只在首次设置时有用）
  if [ -f "$TARGET_DIR/data/security/auth.json" ]; then
    echo "  密码    已设置过，沿用原来的（忘记密码：删掉 data/security/auth.json 再重启）"
  else
    local token=""
    # 优先从文件读（项目把令牌写在 data/security/setup-token.txt，重启也不变）
    if [ -f "$TARGET_DIR/data/security/setup-token.txt" ]; then
      token="$(tr -d ' \r\n' < "$TARGET_DIR/data/security/setup-token.txt" 2>/dev/null || true)"
    fi
    if [ -z "$token" ] && [ -n "$CONTAINER" ]; then
      token="$(docker logs "$CONTAINER" 2>&1 | grep -oE '首次设置令牌[:：]? *[0-9a-fA-F]{16,}' | tail -n1 | grep -oE '[0-9a-fA-F]{16,}' || true)"
    fi
    if [ -n "$token" ]; then
      echo "  令牌    $token"
      echo "          （首次设置密码时填这个；设置完成后系统会自动删掉它）"
    else
      echo "  令牌    没取到，手动看：docker logs $CONTAINER | grep -i 令牌"
    fi
  fi
  [ -n "$NOTE" ] && echo "  说明    $NOTE"
  if [ "$BIND_LOOPBACK" = 1 ]; then
    echo "  访问    仅本机：ssh -L 9000:127.0.0.1:9000 root@$ip  然后浏览器开 http://127.0.0.1:9000"
  else
    [ -n "$ui_port" ] && echo "  访问    http://$ip:$ui_port"
  fi
  if [ -n "$PORTS_DISPLAY" ]; then
    echo "  放行    云服务器要在安全组/防火墙放行这些端口：${PORTS_DISPLAY//,/, }（否则外部打不开）"
  fi
  echo "  日志    $DI_LOG"

  # ---------- 可选：清理源码 ----------
  if [ "$CLEAN_SRC" = 1 ]; then
    info "--clean-src：删除源码，只保留运行所需"
    for p in scripts ui docs Dockerfile entrypoint.sh .dockerignore .env.example README.md 部署手册.md; do
      rm -rf "${TARGET_DIR:?}/$p"
    done
    rm -f "$TARGET_DIR"/*.md
    ok "源码已清理（以后不能再 docker compose build，只能直接用现有镜像）"
  fi
}

# ======================================================================
# 依次安装所有选中的项目
# ======================================================================
for pj in "${PROJECTS[@]}"; do
  install_one "$pj"
  echo
done

if [ "${#PROJECTS[@]}" -gt 1 ]; then
  echo "全部完成：${PROJECTS[*]}"
  echo "根目录：$ROOT_DIR"
fi

# ======================================================================
# 可选：顺便签一张 HTTPS 证书（不用填服务商的密钥）
# ======================================================================
offer_cert() {
  [ "$UNINSTALL" = 1 ] && return 0
  [ "$DRY_RUN" = 1 ] && return 0
  [ -n "$TTY_FD" ] || return 0

  local pj have=0 domain email tmp
  for pj in "${PROJECTS[@]}"; do
    [ -d "$ROOT_DIR/$pj/data/certs" ] && have=1
  done
  [ "$have" = 1 ] || return 0

  echo
  info "顺手把 HTTPS 也办了？（可选，直接回车 = 先不签）"
  echo "  不填服务商密钥、不停现有网站：80 端口空着就直接签，被别的网站占着就借用它的目录。"
  echo "  签完再决定给哪个代理用，随时可以再跑一次。"
  ask "现在签一张证书吗？(y/N)" "n"
  case "$REPLY" in
    y|Y|yes|YES) ;;
    *) echo "  以后随时可以跑：sudo bash $ROOT_DIR/cert.sh 你的域名"; return 0 ;;
  esac

  # 输入不对就重问，不静默跳过；直接回车 = 不签（明确说一声）
  domain=""
  while :; do
    ask "要签的域名（例如 emby.abc.com；直接回车=先不签）" ""
    domain="$REPLY"
    if [ -z "$domain" ]; then
      echo "  好，先不签。以后随时可以：sudo bash $ROOT_DIR/cert.sh 你的域名"
      return 0
    fi
    case "$domain" in
      *[!a-zA-Z0-9.-]*|.*|*..*|*.)
        warn "域名只能有字母、数字、点和横线，而且不能以点开头或结尾，重新输入"; continue ;;
    esac
    case "$domain" in
      *.*) break ;;
      *) warn "域名中间要有点（像 emby.abc.com 这样），重新输入"; continue ;;
    esac
  done

  tmp="$(mktemp -d)"
  if ! fetch "cert.sh" "$tmp/cert.sh"; then
    warn "拉不到 cert.sh（不影响安装）"
    rm -rf "$tmp"; return 0
  fi
  cp -f "$tmp/cert.sh" "$ROOT_DIR/cert.sh" 2>/dev/null || true
  chmod +x "$ROOT_DIR/cert.sh" 2>/dev/null || true

  echo
  cert_extra=()
  [ -n "${ACME_EMAIL:-}" ] && cert_extra=(--email "$ACME_EMAIL")
  if bash "$tmp/cert.sh" "$domain" --dir "$ROOT_DIR" "${cert_extra[@]}" --no-install; then
    echo
    ok "证书签好了：$ROOT_DIR/_certs/$domain/"
    echo "  下一步把这张证书挂到代理上（会顺便告诉你最终访问地址）："
    echo "    1) 管理台「代理」里把域名填成 $domain 并保存"
    echo "    2) 跑一次：sudo bash $ROOT_DIR/cert.sh $domain"
    echo "       （证书还有效，不会重复签；它只问你要挂到哪个代理，挂完打印访问地址，"
    echo "         并问你要不要配自动续期）"
    echo "    3) 管理台「证书」里把「HTTPS 模式」选成本端口直接 HTTPS，或跳转到共用 HTTPS 端口"
  else
    warn "这次没签成（不影响已经装好的服务）。稍后重试：sudo bash $ROOT_DIR/cert.sh $domain"
  fi
  rm -rf "$tmp"
}

offer_cert