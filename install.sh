#!/usr/bin/env bash
# docker-installer —— 一条命令把私有 compose 项目装到服务器上
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
#   --clean-src         装好后删掉源码文件（只留镜像、data/、proxies/，之后不能再重建）
#   --force             目标目录已存在时，先备份再覆盖
#   --dry-run           只下载/校验/解密/解压，不构建也不启动
#   --no-start          只构建镜像，不启动容器
#   --password-stdin    从标准输入读密码（不推荐，优先交互输入）
#   --base <URL>        只用指定的安装器来源（默认按 GitHub raw → jsDelivr → ghfast 依次尝试）
#   -h, --help          帮助
#
# 环境变量：
#   INSTALLER_BASE      安装器根地址；也可指向本地目录做测试，例如 file:///tmp/inst
#   INSTALLER_PBKDF2_ITER  解密迭代次数，默认 600000（必须与打包时一致）
set -euo pipefail

VERSION="1.0.0"
# 安装器根地址：显式指定（--base / INSTALLER_BASE）时只用它；
# 否则按下面的镜像列表依次尝试 —— 国内直连 raw.githubusercontent.com 经常拉不动。
BASE="${INSTALLER_BASE:-}"
MIRRORS=(
  "https://raw.githubusercontent.com/txzl130/docker-installer/main"
  "https://cdn.jsdelivr.net/gh/txzl130/docker-installer@main"
  "https://ghfast.top/https://raw.githubusercontent.com/txzl130/docker-installer/main"
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

while [ $# -gt 0 ]; do
  case "$1" in
    --list)           LIST=1; shift ;;
    --dir)            TARGET_DIR="${2:-}"; [ -n "$TARGET_DIR" ] || die "--dir 需要一个路径"; shift 2 ;;
    --clean-src)      CLEAN_SRC=1; shift ;;
    --force)          FORCE=1; shift ;;
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

fetch_one() { # $1 = 完整源地址，$2 = 输出文件
  local src="$1" out="$2"
  case "$src" in
    http://*|https://*)
      # max-time / speed-limit：网络卡住时 30 秒内低于 2KB/s 就放弃，不会无限挂着
      curl -fsSL --connect-timeout 15 --max-time 300 \
        --speed-limit 2048 --speed-time 30 --retry 1 "$src" -o "$out" ;;
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
    if fetch_one "$base/$rel" "$out"; then BASE="$base"; return 0; fi
    warn "这个源拉不动，换下一个：$base"
  done
  return 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# ---------- --list ----------
if [ "$LIST" = 1 ]; then
  need curl
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  fetch "projects/list.txt" "$tmp/list.txt" || die "拉不到项目列表（试过所有镜像），可用 --base 指定源"
  printf '%-28s %-22s %s\n' "项目" "默认目录" "说明"
  while IFS='|' read -r n t d; do
    [ -n "${n:-}" ] || continue
    printf '%-28s %-22s %s\n' "$n" "$t" "$d"
  done < "$tmp/list.txt"
  exit 0
fi

[ -n "$PROJECT" ] || { usage; echo; die "请指定项目名，或用 --list 看有哪些"; }

# ---------- 准备 ----------
need curl; need openssl; need tar
tmp="$(mktemp -d)"; chmod 700 "$tmp"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

info "项目：$PROJECT"
fetch "projects/$PROJECT/project.conf" "$tmp/project.conf" \
  || die "找不到项目 $PROJECT（源：$BASE）——用 --list 看有哪些项目"

# 读取元数据（只认 KEY=VALUE，不执行里面的任何命令）
NAME=""; TITLE=""; DIR_CONF=""; PORTS=""; ENV_FROM=""; IMAGE=""; CONTAINER=""
PKG=""; PKG_SHA256=""; TAR_SHA256=""; NOTE=""
while IFS='=' read -r k v; do
  case "$k" in
    NAME) NAME="$v" ;; TITLE) TITLE="$v" ;; DIR) DIR_CONF="$v" ;; PORTS) PORTS="$v" ;;
    ENV_FROM) ENV_FROM="$v" ;; IMAGE) IMAGE="$v" ;; CONTAINER) CONTAINER="$v" ;;
    PKG) PKG="$v" ;; PKG_SHA256) PKG_SHA256="$v" ;; TAR_SHA256) TAR_SHA256="$v" ;; NOTE) NOTE="$v" ;;
  esac
done < "$tmp/project.conf"

[ -n "$NAME" ] || NAME="$PROJECT"
[ -n "$PKG" ] || die "project.conf 缺少 PKG"
TARGET_DIR="${TARGET_DIR:-${DIR_CONF:-/opt/ysf/docker/$NAME}}"

info "标题：${TITLE:-$NAME}"
info "目录：$TARGET_DIR"
[ -n "$PORTS" ] && info "端口：$PORTS"

# ---------- 环境检查 ----------
if [ "$DRY_RUN" = 0 ]; then
  need docker
  docker compose version >/dev/null 2>&1 || die "docker compose 不可用（需要 Compose v2）"
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') 已就绪"
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

# ---------- 释放到目标目录 ----------
if [ -d "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null || true)" ]; then
  if [ "$FORCE" = 1 ]; then
    bak="$TARGET_DIR.bak.$(date +%Y%m%d-%H%M%S)"
    info "目标目录非空，备份到 $bak"
    mv "$TARGET_DIR" "$bak"
  else
    die "目录已存在且不为空：$TARGET_DIR
  想覆盖就加 --force（会先备份），或换一个 --dir"
  fi
fi
mkdir -p "$TARGET_DIR"
tar -xzf "$tmp/pkg.tar.gz" -C "$TARGET_DIR"
ok "已释放到 $TARGET_DIR"

# ---------- .env ----------
if [ -n "$ENV_FROM" ] && [ ! -f "$TARGET_DIR/.env" ] && [ -f "$TARGET_DIR/$ENV_FROM" ]; then
  cp "$TARGET_DIR/$ENV_FROM" "$TARGET_DIR/.env"
  ok "已生成 .env（来自 $ENV_FROM，可自行修改）"
fi

if [ "$DRY_RUN" = 1 ]; then
  info "dry-run：不构建、不启动"
  ls -la "$TARGET_DIR"
  exit 0
fi

# ---------- 构建 + 启动 ----------
cd "$TARGET_DIR"
info "构建镜像（首次约 1～2 分钟）"
BUILT_BY_COMPOSE=1
if ! docker compose build; then
  warn "docker compose build 失败，改用 docker build --network host"
  img="$(docker compose config --images 2>/dev/null | head -n1 || true)"
  [ -n "$img" ] || img="${IMAGE:-$NAME:local}"
  docker build --network host -t "$img" . || die "构建失败"
  ok "已用 --network host 构建出 $img"
  BUILT_BY_COMPOSE=0
fi

if [ "$NO_START" = 1 ]; then
  ok "镜像已构建（--no-start，未启动容器）"
  exit 0
fi

info "启动容器"
if [ "$BUILT_BY_COMPOSE" = 1 ]; then
  docker compose up -d --remove-orphans || die "启动失败，看上面的报错"
else
  docker compose up -d --remove-orphans --no-build || die "启动失败，看上面的报错"
fi

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
    *) warn "容器状态：$status（继续，请自行 docker logs $CONTAINER 查看）" ;;
  esac
fi

# ---------- 输出结果 ----------
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$ip" ] || ip="<本机IP>"
echo
printf '%s安装完成%s\n' "$c_grn" "$c_reset"
[ -n "$PORTS" ] && echo "  端口    $PORTS"
echo "  目录    $TARGET_DIR"
if [ -n "$CONTAINER" ]; then
  token="$(docker logs "$CONTAINER" 2>&1 | grep -E '令牌|token' | tail -n 3 || true)"
  if [ -n "$token" ]; then
    echo "  ${token}"
  fi
fi
[ -n "$NOTE" ] && echo "  说明    $NOTE"
echo "  访问    http://$ip:${PORTS%%,*}"

# ---------- 可选：清理源码 ----------
if [ "$CLEAN_SRC" = 1 ]; then
  info "--clean-src：删除源码，只保留运行所需"
  for p in scripts ui docs Dockerfile entrypoint.sh .dockerignore .env.example README.md 部署手册.md; do
    rm -rf "${TARGET_DIR:?}/$p"
  done
  rm -f "$TARGET_DIR"/*.md
  ok "源码已清理（以后不能再 docker compose build，只能直接用现有镜像）"
fi
