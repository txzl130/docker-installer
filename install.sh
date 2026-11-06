#!/usr/bin/env bash
# docker-installer —— 一条命令把私有 compose 项目装到服务器上（支持升级）
# 仓库：https://github.com/txzl130/docker-installer
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/txzl130/docker-installer/main/install.sh | bash -s -- emby-proxy-manager
#   # 国内 raw 拉不动就用 jsDelivr：
#   curl -fsSL https://cdn.jsdelivr.net/gh/txzl130/docker-installer@main/install.sh | bash -s -- emby-proxy-manager
#   ./install.sh --list
#   ./install.sh emby-proxy-manager --dir /opt/ysf/docker/emby-proxy-manager
#
# 参数：
#   --list              列出所有可安装的项目
#   --dir <路径>        指定安装目录（默认取 project.conf 里的 DIR）
#   --upgrade           升级已安装的目录（默认行为：目录里已有 docker-compose.yml 时自动升级）
#   --reinstall         重新安装：整个目录先备份成 .bak，再按全新安装（数据也会被带走）
#   --force             --reinstall 的别名
#   --clean-src         装好后删掉源码文件（只留镜像、data/、proxies/，之后不能再重建）
#   --dry-run           只下载/校验/解密/解压，不构建也不启动
#   --no-start          只构建镜像，不启动容器
#   --password-stdin    从标准输入读密码（不推荐，优先交互输入）
#   --base <URL>        只用指定的安装器来源（默认按 GitHub raw → jsDelivr → ghfast 依次尝试）
#   -h, --help          帮助
#
# 环境变量：
#   INSTALLER_BASE      安装器根地址；也可指向本地目录做测试，例如 file:///tmp/inst
#   INSTALLER_PBKDF2_ITER  解密迭代次数，默认 600000（必须与打包时一致）
#   UI_PORT / HEALTH_PORT  覆盖项目默认端口（9000、8080 被占用时最常用）
set -euo pipefail

VERSION="1.1.0"
# 安装器根地址：显式指定（--base / INSTALLER_BASE）时只用它；
# 否则按下面的镜像列表依次尝试 —— 国内直连 raw.githubusercontent.com 经常拉不动。
BASE="${INSTALLER_BASE:-}"
MIRRORS=(
  "https://cdn.jsdelivr.net/gh/txzl130/docker-installer@main"
  "https://ghfast.top/https://raw.githubusercontent.com/txzl130/docker-installer/main"
  "https://raw.githubusercontent.com/txzl130/docker-installer/main"
  "https://gh-proxy.com/https://raw.githubusercontent.com/txzl130/docker-installer/main"
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

PROJECT=""; TARGET_DIR=""; CLEAN_SRC=0; FORCE=0; DRY_RUN=0; LIST=0; PW_STDIN=0; NO_START=0
MODE=""   # fresh / upgrade / reinstall（空 = 自动判断）

while [ $# -gt 0 ]; do
  case "$1" in
    --list)           LIST=1; shift ;;
    --dir)            TARGET_DIR="${2:-}"; [ -n "$TARGET_DIR" ] || die "--dir 需要一个路径"; shift 2 ;;
    --upgrade)        MODE="upgrade"; shift ;;
    --reinstall)      MODE="reinstall"; shift ;;
    --force)          MODE="reinstall"; shift ;;
    --clean-src)      CLEAN_SRC=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --no-start)       NO_START=1; shift ;;
    --password-stdin) PW_STDIN=1; shift ;;
    --base)           BASE="${2:-}"; [ -n "$BASE" ] || die "--base 需要一个地址"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    --version)        echo "docker-installer $VERSION"; exit 0 ;;
    -*)               die "未知参数：$1（用 --help 看用法）" ;;
    *)                [ -z "$PROJECT" ] || die "只能指定一个项目"; PROJECT="$1"; shift ;;
  esac
done

# 全程留一份日志，出问题时让用户直接发这个文件
if [ -z "${DI_LOG:-}" ]; then
  DI_LOG="/tmp/docker-installer-$(date +%Y%m%d-%H%M%S).log"
  export DI_LOG
  exec > >(tee -a "$DI_LOG") 2>&1
fi

fetch_one() { # $1 = 完整源地址，$2 = 输出文件
  local src="$1" out="$2"
  case "$src" in
    http://*|https://*)
      # 单个源最多等 120 秒：raw 在国内经常「连上了但一个字节也不给」，
      # 等太久会让人以为卡死；2KB/s 是历史经验值，低于它就换源。
      curl -fsSL --connect-timeout 10 --max-time 120 \
        --speed-limit 512 --speed-time 40 "$src" -o "$out" ;;
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
    if fetch_one "$base/$rel" "$out"; then BASE="$base"; ok "下载源：$base"; return 0; fi
    warn "这个源拉不动，换下一个：$base"
  done
  return 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

port_busy() { # $1 = 端口；被占用返回 0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1\$"
  else
    netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "[:.]$1\$"
  fi
}

# ---------- --list ----------
if [ "$LIST" = 1 ]; then
  need curl
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  fetch "projects/list.txt" "$tmp/list.txt" || die "拉不到项目列表（试过所有镜像），可用 --base 指定源"
  printf '%-24s %-18s %-20s %s\n' "项目" "版本" "默认目录" "说明"
  while IFS='|' read -r n t d v; do
    [ -n "${n:-}" ] || continue
    printf '%-24s %-18s %-20s %s\n' "$n" "${v:--}" "${d:--}" "$t"
  done < "$tmp/list.txt"
  exit 0
fi

[ -n "$PROJECT" ] || { usage; echo; die "请指定项目名，或用 --list 看有哪些"; }

# ---------- 准备 ----------
need curl; need openssl; need tar; need sha256sum
tmp="$(mktemp -d)"; chmod 700 "$tmp"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

info "项目：$PROJECT"
fetch "projects/$PROJECT/project.conf" "$tmp/project.conf" \
  || die "找不到项目 $PROJECT（源：$BASE）——用 --list 看有哪些项目"

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

[ -n "$NAME" ] || NAME="$PROJECT"
[ -n "$PKG" ] || die "project.conf 缺少 PKG"
TARGET_DIR="${TARGET_DIR:-${DIR_CONF:-/opt/ysf/docker/$NAME}}"
# 一律转成绝对路径（后面会 cd，相对路径会错位）
case "$TARGET_DIR" in
  /*) ;;
  *)  TARGET_DIR="$(pwd)/$TARGET_DIR" ;;
esac

# ---------- 判断是 新装 / 升级 / 重装 ----------
INSTALLED_VERSION=""
if [ -f "$TARGET_DIR/.installed-version" ]; then
  INSTALLED_VERSION="$(head -n1 "$TARGET_DIR/.installed-version" 2>/dev/null || true)"
fi
IS_EXISTING=0
[ -f "$TARGET_DIR/docker-compose.yml" ] && IS_EXISTING=1

if [ -z "$MODE" ]; then
  if [ "$IS_EXISTING" = 1 ]; then MODE="upgrade"; else MODE="fresh"; fi
fi
if [ "$MODE" = "upgrade" ] && [ "$IS_EXISTING" != 1 ]; then
  die "目录 $TARGET_DIR 里没有 docker-compose.yml，不能升级（要新装就去掉 --upgrade）"
fi

info "标题：${TITLE:-$NAME}"
info "目录：$TARGET_DIR"
[ -n "$PORTS" ] && info "端口：$PORTS"
if [ "$MODE" = "upgrade" ]; then
  info "模式：升级 ${INSTALLED_VERSION:-（未知版本）} → ${PKG_VERSION:-（未知版本）}"
elif [ "$MODE" = "reinstall" ]; then
  info "模式：重新安装（旧目录会备份成 .bak）"
else
  info "模式：全新安装${PKG_VERSION:+（版本 $PKG_VERSION）}"
fi

# ---------- 环境检查 ----------
if [ "$DRY_RUN" = 0 ]; then
  need docker
  docker compose version >/dev/null 2>&1 || die "docker compose 不可用（需要 Compose v2）"
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') 已就绪"
  # 磁盘：构建 + 缓存，留 2G 以下容易半路失败
  avail_k="$(df -Pk "$(dirname "$TARGET_DIR")" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  if [ -n "$avail_k" ] && [ "$avail_k" -lt 2097152 ] 2>/dev/null; then
    warn "目标磁盘只剩 $((avail_k / 1024)) MB，可能不够构建（建议至少 2 GB）"
  fi
fi

# ---------- 下载 + 校验 ----------
info "下载安装包 $PKG"
fetch "projects/$PROJECT/$PKG" "$tmp/pkg.enc" || die "下载失败：$BASE/projects/$PROJECT/$PKG"
if [ -n "$PKG_SHA256" ]; then
  got="$(sha256sum "$tmp/pkg.enc" | awk '{print $1}')"
  [ "$got" = "$PKG_SHA256" ] || die "安装包校验失败（可能被改动过）
  期望 $PKG_SHA256
  实际 $got"
  ok "校验通过"
fi

# ---------- 密码 ----------
PW=""
if [ "$PW_STDIN" = 1 ]; then
  IFS= read -r PW || true
elif [ -n "${INSTALLER_PASSWORD:-}" ]; then
  PW="$INSTALLER_PASSWORD"
else
  [ -t 0 ] || die "没有终端，无法交互输入密码（可用 --password-stdin）"
  printf '请输入安装密码：' >&2
  IFS= read -rs PW || true
  printf '\n' >&2
fi
[ -n "$PW" ] || die "密码为空"

# ---------- 解密 ----------
info "解密"
if ! printf '%s' "$PW" | openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" \
      -in "$tmp/pkg.enc" -out "$tmp/pkg.tar.gz" -pass stdin 2>/dev/null; then
  die "解密失败：密码不对，或安装包损坏"
fi
if [ -n "$TAR_SHA256" ]; then
  got="$(sha256sum "$tmp/pkg.tar.gz" | awk '{print $1}')"
  [ "$got" = "$TAR_SHA256" ] || die "解密后内容校验失败（安装包可能被替换）"
fi
ok "解密成功"

# 先解到临时目录，确认是完整项目再动目标目录
mkdir -p "$tmp/new"
tar -xzf "$tmp/pkg.tar.gz" -C "$tmp/new"
[ -f "$tmp/new/docker-compose.yml" ] || die "安装包内容不对：里面没有 docker-compose.yml"

if [ "$DRY_RUN" = 1 ]; then
  info "dry-run：不构建、不启动"
  echo "  安装包内容："
  ls -la "$tmp/new" | sed 's/^/    /'
  info "目标目录将变为：$TARGET_DIR（模式：$MODE）"
  exit 0
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

# ---------- 端口预检 ----------
# 有效端口：项目声明的端口列表，第一项是管理台（可用 UI_PORT 覆盖）
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
  die "这些端口已被别的程序占用：${busy}
  处理办法（任选）：
    1) 空出端口：ss -ltnp | grep -E ':(5088|9000) ' 找到进程后停掉
    2) 换个端口装：UI_PORT=19000 HEALTH_PORT=18080 bash install.sh $PROJECT --dir $TARGET_DIR
    3) 装完再改 $TARGET_DIR/.env，然后 docker compose up -d"
fi
ok "端口空闲：$eff_ports"

# ---------- 构建 + 启动 ----------
cd "$TARGET_DIR"
info "构建镜像（首次约 1～2 分钟）"
BUILT_BY_COMPOSE=1
# Docker 29 起 build.network=host 需要显式授权，否则 compose build 会直接报
# "additional privileges requested"（以前只能靠失败后回退）
if ! BUILDX_ENTITLEMENTS=network.host docker compose build; then
  warn "docker compose build 失败，改用 docker build --network host"
  img="$(docker compose config --images 2>/dev/null | head -n1 || true)"
  [ -n "$img" ] || img="${IMAGE:-$NAME:local}"
  docker build --network host -t "$img" . || die "构建失败（日志：$DI_LOG）"
  ok "已用 --network host 构建出 $img"
  BUILT_BY_COMPOSE=0
fi

if [ "$NO_START" = 1 ]; then
  ok "镜像已构建（--no-start，未启动容器）"
  echo "$PKG_VERSION" > "$TARGET_DIR/.installed-version"
  exit 0
fi

info "启动容器"
docker compose up -d --remove-orphans --no-build >/dev/null || die "启动失败（日志：$DI_LOG）"

# ---------- 等健康 ----------
if [ -n "$CONTAINER" ]; then
  info "等待容器就绪"
  n=0; status=""
  while [ $n -lt 60 ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo missing)"
    case "$status" in
      healthy|running) break ;;
      missing) break ;;
    esac
    n=$((n + 1)); sleep 2
  done
  case "$status" in
    healthy|running) ok "容器状态：$status" ;;
    *) warn "容器状态：$status（继续，排查：docker logs --tail 50 $CONTAINER）" ;;
  esac
fi

# ---------- 记录版本 ----------
echo "$PKG_VERSION" > "$TARGET_DIR/.installed-version" 2>/dev/null || true

# ---------- 输出结果 ----------
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$ip" ] || ip="<本机IP>"
# 管理台端口：环境里显式设了 UI_PORT 就以它为准（典型场景：9000 被别的服务占了）
ui_port="${UI_PORT:-${PORTS%%,*}}"
echo
if [ "$MODE" = "upgrade" ]; then
  printf '%s升级完成%s\n' "$c_grn" "$c_reset"
  echo "  版本    ${INSTALLED_VERSION:-?} → ${PKG_VERSION:-?}"
else
  printf '%s安装完成%s\n' "$c_grn" "$c_reset"
  [ -n "$PKG_VERSION" ] && echo "  版本    $PKG_VERSION"
fi
[ -n "$PORTS" ] && echo "  端口    $PORTS"
echo "  目录    $TARGET_DIR"

# 密码是否已经设过：设过就不打印令牌（令牌只在首次设置时有用）
if [ -f "$TARGET_DIR/data/security/auth.json" ]; then
  echo "  密码    已设置过，沿用原来的（忘记密码：删掉 data/security/auth.json 再重启）"
else
  token="$(docker logs "$CONTAINER" 2>&1 | grep -E '令牌|token' | tail -n 3 || true)"
  [ -n "$token" ] && echo "  ${token}"
fi
[ -n "$NOTE" ] && echo "  说明    $NOTE"
[ -n "$ui_port" ] && echo "  访问    http://$ip:$ui_port"
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
