#!/usr/bin/env bash
# publish.sh —— 把一个私有 compose 项目打成加密安装包，发布到 docker-installer 仓库
#
# 用法：
#   ./publish.sh <项目名> <源码目录> [选项]
#
# 例子：
#   ./publish.sh emby-proxy-manager /d/项目/emby-proxy-manager \
#       --title "Emby 反代管理器" --dir /opt/ysf/docker/emby-proxy-manager \
#       --ports 9000,5088,11238,6088 --image emby-proxy-manager:local \
#       --container emby-proxy-manager --note "首次启动会在日志里打印设置令牌"
#
# 选项：
#   --title <文字>      显示名称
#   --dir <路径>        默认安装目录（服务器上的）
#   --ports <列表>      涉及端口，逗号分隔（只用于提示）
#   --env-from <文件>   没有 .env 时从这个模板复制（一般是 .env.example）
#   --image <镜像名>    回退构建时用的镜像 tag（docker build --network host 用）
#   --container <名字>  容器名，用于等待健康和打印日志
#   --note <文字>       安装完成后显示的一句话
#   --version <文字>    指定这次的版本号（默认自动取 VERSION 文件 / package.json / git 短哈希）
#   --allow-secrets     扫描到疑似凭据也继续（默认中止）
#   --no-push           只提交到本地，不 push
#
# 打包会自动排除：.git  .env  data/  node_modules/  *.pem  *.key  *.log  docs/screenshots
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITER="${INSTALLER_PBKDF2_ITER:-600000}"

c_reset=""; c_red=""; c_grn=""; c_yel=""; c_dim=""
if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'
fi
info() { printf '%s==>%s %s\n' "$c_dim" "$c_reset" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
die()  { printf '%s[xx]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

NAME=""; SRC=""
TITLE=""; DIR_DEF=""; PORTS=""; ENV_FROM=""; IMAGE=""; CONTAINER=""; NOTE=""
VER=""
ALLOW_SECRETS=0; DO_PUSH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --title)        TITLE="${2:-}"; shift 2 ;;
    --dir)          DIR_DEF="${2:-}"; shift 2 ;;
    --ports)        PORTS="${2:-}"; shift 2 ;;
    --env-from)     ENV_FROM="${2:-}"; shift 2 ;;
    --image)        IMAGE="${2:-}"; shift 2 ;;
    --container)    CONTAINER="${2:-}"; shift 2 ;;
    --note)         NOTE="${2:-}"; shift 2 ;;
    --version)      VER="${2:-}"; shift 2 ;;
    --allow-secrets) ALLOW_SECRETS=1; shift ;;
    --no-push)      DO_PUSH=0; shift ;;
    -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)             die "未知参数：$1" ;;
    *)              if [ -z "$NAME" ]; then NAME="$1"; elif [ -z "$SRC" ]; then SRC="$1"; else die "参数太多：$1"; fi; shift ;;
  esac
done

[ -n "$NAME" ] && [ -n "$SRC" ] || die "用法：publish.sh <项目名> <源码目录>"
[ -d "$SRC" ] || die "源码目录不存在：$SRC"
SRC="$(cd "$SRC" && pwd)"
for c in tar openssl sha256sum git; do command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"; done

[ -n "$TITLE" ] || TITLE="$NAME"
[ -n "$DIR_DEF" ] || DIR_DEF="/opt/ysf/docker/$NAME"

# 版本号：--version 优先；否则依次看源码里的 VERSION 文件、package.json、git 短哈希
if [ -z "$VER" ]; then
  if [ -f "$SRC/VERSION" ]; then
    VER="$(head -n1 "$SRC/VERSION" | tr -d '[:space:]')"
  elif [ -f "$SRC/package.json" ]; then
    VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/package.json" | head -n1)"
  fi
fi
if [ -z "$VER" ] && git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
  VER="$(git -C "$SRC" rev-parse --short HEAD)"
fi
[ -n "$VER" ] || VER="$(date +%Y%m%d-%H%M)"
info "版本：$VER"

info "项目：$NAME"
info "源码：$SRC"
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  head="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo '-')"
  dirty="$(git -C "$SRC" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  info "提交：$head（未提交改动 $dirty 个文件）"
  [ "$dirty" = 0 ] || warn "工作区有未提交改动，打出来的包会包含这些改动"
fi

tmp="$(mktemp -d)"; chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

# ---------- 打包 ----------
info "打包（排除 .git / .env / data / 证书 / 日志 / 截图）"
TAR_FMT=""
if tar --help 2>&1 | grep -q -- '--format=gnu'; then TAR_FMT="--format=gnu"; fi
tar $TAR_FMT -czf "$tmp/pkg.tar.gz" -C "$SRC" \
  --exclude='./.git' --exclude='./.git/*' \
  --exclude='.env' --exclude='.env.local' \
  --exclude='data' --exclude='./data/*' \
  --exclude='node_modules' \
  --exclude='*.pem' --exclude='*.key' --exclude='*.p12' --exclude='*.pfx' \
  --exclude='*.log' --exclude='*.tgz' --exclude='*.zip' \
  --exclude='./docs/screenshots' \
  . || die "打包失败"

# 保险：确认敏感文件没进去
if tar -tzf "$tmp/pkg.tar.gz" | grep -qE '(^|/)\.env$|(^|/)data/|\.pem$|\.key$'; then
  die "包里出现了 .env / data / 证书私钥，已中止"
fi

# ---------- 凭据扫描 ----------
info "扫描疑似凭据"
rm -rf "$tmp/scan"; mkdir -p "$tmp/scan"
tar -xzf "$tmp/pkg.tar.gz" -C "$tmp/scan"
if grep -RInE \
    -e 'BEGIN [A-Z ]*PRIVATE KEY' \
    -e 'ghp_[A-Za-z0-9]{20,}' \
    -e 'github_pat_[A-Za-z0-9_]{20,}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e '(password|passwd|secret|api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_./+=-]{16,}["'"'"']' \
    "$tmp/scan" > "$tmp/hits.txt" 2>/dev/null; then
  warn "发现疑似凭据："
  head -n 20 "$tmp/hits.txt" | sed 's/^/    /' >&2
  if [ "$ALLOW_SECRETS" = 1 ]; then
    warn "--allow-secrets 已指定，继续"
  else
    die "已中止。确认没问题可加 --allow-secrets 重跑"
  fi
else
  ok "未发现明显凭据"
fi

# ---------- 密码 ----------
PW=""
if [ -n "${INSTALLER_PASSWORD:-}" ]; then
  PW="$INSTALLER_PASSWORD"
else
  [ -t 0 ] || die "没有终端，无法交互输入密码（可设 INSTALLER_PASSWORD 环境变量）"
  printf '设置安装密码（至少 16 位）：' >&2
  IFS= read -rs PW || true; printf '\n' >&2
  printf '再输一次：' >&2
  IFS= read -rs PW2 || true; printf '\n' >&2
  [ "$PW" = "$PW2" ] || die "两次输入不一致"
fi
[ "${#PW}" -ge 16 ] || die "密码太短（至少 16 位）"

# ---------- 加密 ----------
info "加密"
printf '%s' "$PW" | openssl enc -aes-256-cbc -pbkdf2 -iter "$ITER" -salt \
  -in "$tmp/pkg.tar.gz" -out "$tmp/pkg.enc" -pass stdin || die "加密失败"

pkg_sha="$(sha256sum "$tmp/pkg.enc" | awk '{print $1}')"
tar_sha="$(sha256sum "$tmp/pkg.tar.gz" | awk '{print $1}')"
size="$(wc -c < "$tmp/pkg.enc" | tr -d ' ')"

# ---------- 自检：用同一密码立刻解回来 ----------
# 这一步很关键：曾经出现过「加密时用的密码和约定的不一样」，
# 结果包能上传、SHA256 也自洽，安装时却永远「密码不对」。
if ! printf '%s' "$PW" | openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" \
      -in "$tmp/pkg.enc" -out "$tmp/verify.tar.gz" -pass stdin 2>/dev/null; then
  die "自检失败：加密后的包用同一密码解不开（openssl 有问题），未写入仓库"
fi
verify_sha="$(sha256sum "$tmp/verify.tar.gz" | awk '{print $1}')"
[ "$verify_sha" = "$tar_sha" ] || die "自检失败：解出来的内容和原包不一致，未写入仓库"
ok "自检通过（解密后校验和一致）"
pw_check="$(printf '%s' "$PW" | sha256sum | cut -c1-12)"

# ---------- 写入仓库 ----------
dest="$REPO_ROOT/projects/$NAME"
mkdir -p "$dest"
cp "$tmp/pkg.enc" "$dest/$NAME.tar.gz.enc"

cat > "$dest/project.conf" <<EOF
NAME=$NAME
TITLE=$TITLE
VERSION=$VER
DIR=$DIR_DEF
PORTS=$PORTS
ENV_FROM=$ENV_FROM
IMAGE=$IMAGE
CONTAINER=$CONTAINER
PKG=$NAME.tar.gz.enc
PKG_SHA256=$pkg_sha
TAR_SHA256=$tar_sha
PW_CHECK=$pw_check
NOTE=$NOTE
EOF

# 重新生成列表
: > "$REPO_ROOT/projects/list.txt"
for d in "$REPO_ROOT"/projects/*/; do
  [ -f "$d/project.conf" ] || continue
  n=""; t=""; dd=""; vv=""
  while IFS='=' read -r k v; do
    case "$k" in NAME) n="$v" ;; TITLE) t="$v" ;; DIR) dd="$v" ;; VERSION) vv="$v" ;; esac
  done < "$d/project.conf"
  [ -n "$n" ] && printf '%s|%s|%s|%s\n' "$n" "$t" "$dd" "$vv" >> "$REPO_ROOT/projects/list.txt"
done

ok "已生成 projects/$NAME/（加密包 $size 字节）"
printf '    tar sha256 %s\n    pkg sha256 %s\n' "$tar_sha" "$pkg_sha"

# ---------- 提交 ----------
cd "$REPO_ROOT"
git add -A
if git diff --cached --quiet; then
  ok "没有变化，不提交"
else
  git commit -q -m "publish: $NAME ($(date +%Y-%m-%d))" || die "提交失败"
  if [ "$DO_PUSH" = 1 ]; then
    git push -q || die "push 失败"
    ok "已推送到远端"
  else
    ok "已提交（--no-push，未推送）"
  fi
fi
