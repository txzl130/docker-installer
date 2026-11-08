#!/usr/bin/env bash
# ============================================================================
# cert.sh —— 一条命令给域名签 HTTPS 证书（不用填服务商密钥，不用停网站）
#
#   用法：
#     sudo bash cert.sh 域名 [选项]
#     sudo bash cert.sh --renew            续期所有已签的证书
#
#   它会自动挑最简单的办法：
#     ① 80 端口空着      → 单独起一个临时容器验证，签完就撤（最省事）
#     ② 80 被网站占着    → 找到那个网站的目录，塞一个验证文件进去（不用停它）
#     ③ 都不行           → 告诉你改用项目自带的证书功能（DNS 方式）
#
#   选项：
#     --dir <路径>       证书存放根目录（默认 /opt/ysf/docker，证书放 <路径>/_certs/<域名>/）
#     --email <邮箱>     可选：证书到期提醒邮箱（不填也能签）
#     --webroot <路径>   手动指定网站目录（跳过自动查找）
#     --staging          用测试环境签（不消耗正式额度，用来验证流程）
#     --no-install       只签不发，不提示装到项目里
#     -v, --verbose      显示细节
#     -h, --help         看这段说明
#
#   签出来的文件：
#     <dir>/_certs/<域名>/fullchain.pem   证书链
#     <dir>/_certs/<域名>/privkey.pem     私钥
#     <dir>/_certs/<域名>/meta.json       签于/到期/方式
# ============================================================================

set -euo pipefail

VERSION="1.0.0"
ROOT_DIR="/opt/ysf/docker"
EMAIL="${ACME_EMAIL:-}"
WEBROOT=""
STAGING=0
NO_INSTALL=0
FORCE=0
VERBOSE=0
RENEW=0
DOMAIN=""

c_reset=""; c_red=""; c_grn=""; c_yel=""; c_dim=""
if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'
fi
info() { printf '%s==>%s %s\n' "$c_dim" "$c_reset" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
die()  { printf '%s[xx]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        ROOT_DIR="${2:-}"; shift 2 ;;
    --email)      EMAIL="${2:-}"; shift 2 ;;
    --webroot)    WEBROOT="${2:-}"; shift 2 ;;
    --staging)    STAGING=1; shift ;;
    --force)      FORCE=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --renew)      RENEW=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    usage ;;
    -*)           die "未知参数：$1（看 --help）" ;;
    *)            DOMAIN="${1#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"; shift ;;
  esac
done

# ---------- 终端（提问要能读，管道运行时走 /dev/tty）----------
TTY_FD=""
if ( : >/dev/tty ) 2>/dev/null; then
  TTY_FD=/dev/tty
elif [ -t 0 ]; then
  TTY_FD=/dev/stdin
fi

ask() { # $1=提示 $2=默认值 → REPLY
  local def="${2:-}" ans="" prompt="$1"
  [ -n "$def" ] && prompt="$prompt [$def]"
  if [ -n "$TTY_FD" ]; then
    printf '%s: ' "$prompt" >&2
    IFS= read -r ans < "$TTY_FD" || ans=""
  fi
  [ -n "$ans" ] || ans="$def"
  REPLY="$ans"
}
say() { printf '%s\n' "$*"; }

# ---------- 基础检查 ----------
command -v docker >/dev/null 2>&1 || die "缺少命令：docker"
docker info >/dev/null 2>&1 || die "docker 没在运行（systemctl start docker 再试）"

port_busy() { # $1=端口 → 0=占用
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1\$"
  else
    netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "[:.]$1\$"
  fi
}

# ============================================================================
# 续期模式
# ============================================================================
if [ "$RENEW" = 1 ]; then
  base="$ROOT_DIR/_certs"
  [ -d "$base" ] || die "还没签过任何证书（$base 不存在）"
  n=0
  for d in "$base"/*/; do
    [ -f "$d/meta.json" ] || continue
    name="$(basename "$d")"
    [ -f "$d/privkey.pem" ] || continue
    left="$(
      openssl x509 -noout -enddate -in "$d/fullchain.pem" 2>/dev/null |
      sed -n 's/^notAfter=//p'
    )"
    [ -n "$left" ] || continue
    days="$(( ( $(date -d "$left" +%s) - $(date +%s) ) / 86400 ))"
    if [ "$days" -ge 30 ]; then
      info "$name 还有 $days 天，跳过"
      continue
    fi
    info "$name 只剩 $days 天，续期"
    if "$0" "$name" --dir "$ROOT_DIR" --email "$EMAIL" --no-install >/dev/null 2>&1; then
      ok "$name 续期完成"
      n=$((n + 1))
    else
      warn "$name 续期失败，请手动跑：bash $0 $name --dir $ROOT_DIR"
    fi
  done
  ok "续期检查结束（实际续期 $n 个）"
  exit 0
fi

[ -n "$DOMAIN" ] || die "要签哪个域名？例如：bash cert.sh emby.example.com"
case "$DOMAIN" in
  *[!a-zA-Z0-9.-]*) die "域名写法不对：$DOMAIN" ;;
  *.*) : ;;
  *) die "这不像一个域名：$DOMAIN（要写完整，如 emby.example.com）" ;;
esac

CERT_DIR="$ROOT_DIR/_certs/$DOMAIN"
mkdir -p "$CERT_DIR"

# ---------- 已经有证书就别重复签（Let's Encrypt 有频率限制）----------
if [ -s "$CERT_DIR/fullchain.pem" ] && [ -s "$CERT_DIR/privkey.pem" ] && [ "$FORCE" != 1 ]; then
  ends="$(openssl x509 -noout -enddate -in "$CERT_DIR/fullchain.pem" 2>/dev/null | sed 's/^notAfter=//')"
  if [ -n "$ends" ]; then
    days="$(( ( $(date -d "$ends" +%s) - $(date +%s) ) / 86400 ))"
    if [ "$days" -ge 30 ]; then
      ok "这个域名已经有证书了（还剩 $days 天），不重复签"
      info "要强制重签加 --force"
      SKIP_ISSUE=1
    fi
  fi
fi

# ============================================================================
# 选一条验证路线
# ============================================================================
METHOD=""
WEBROOT_FOUND=""
SKIP_ISSUE="${SKIP_ISSUE:-0}"
if [ "$SKIP_ISSUE" = 1 ]; then
  expires="$(openssl x509 -noout -enddate -in "$CERT_DIR/fullchain.pem" | sed 's/^notAfter=//')"
  expires_iso="$(date -u -d "$expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$expires")"
  say "  证书    $CERT_DIR/fullchain.pem"
  say "  有效期至 $expires_iso"
  say ""
else

if [ -n "$WEBROOT" ]; then
  [ -d "$WEBROOT" ] || die "指定的网站目录不存在：$WEBROOT"
  METHOD="webroot"; WEBROOT_FOUND="$WEBROOT"
elif ! port_busy 80; then
  METHOD="standalone"
else
  # 80 被占：找一个「把目录挂进容器、且这个目录对外的 /.well-known 可访问」的网站
  info "80 端口被占用，找找能不能借用现有网站的目录"
  probe="acme-probe-$$-$(date +%s)"
  for cname in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    publish="$(docker port "$cname" 2>/dev/null | grep -E '(^|:)80$|:80/tcp' | head -1)"
    [ -n "$publish" ] || continue
    # 该容器挂载的宿主目录（排除容器内系统目录）
    for m in $(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$cname" 2>/dev/null); do
      [ -d "$m" ] || continue
      case "$m" in /etc/*|/usr/*|/var/lib/docker/*|/proc/*|/sys/*) continue ;; esac
      [ -w "$m" ] || continue
      mkdir -p "$m/.well-known/acme-challenge" 2>/dev/null || continue
      printf 'ok' > "$m/.well-known/acme-challenge/$probe" 2>/dev/null || continue
      reachable=0
      for host_hdr in "$DOMAIN" localhost test.local 127.0.0.1; do
        got="$(curl -fsS --max-time 6 -H "Host: $host_hdr" \
          "http://127.0.0.1/.well-known/acme-challenge/$probe" 2>/dev/null || true)"
        [ "$got" = "ok" ] && { reachable=1; break; }
      done
      rm -f "$m/.well-known/acme-challenge/$probe" 2>/dev/null || true
      if [ "$reachable" = 1 ]; then
        METHOD="webroot"; WEBROOT_FOUND="$m"
        [ "$VERBOSE" = 1 ] && ok "借用 $cname 的目录：$m"
        break 2
      fi
      # 兜底：这个目录本来就有 acme-challenge 目录（说明它就是给 ACME 用的）
      if [ -d "$m/.well-known/acme-challenge" ] && [ -z "$WEBROOT_FOUND" ]; then
        WEBROOT_FOUND="$m"
        [ "$VERBOSE" = 1 ] && info "疑似 ACME 目录（未验证通过 HTTP）：$m"
      fi
    done
    if [ -n "$WEBROOT_FOUND" ] && [ -z "$METHOD" ]; then
      METHOD="webroot"
      warn "没验证到 $WEBROOT_FOUND 能被外网读到，先按这个目录试；失败再换 --webroot 指定"
      break
    fi
  done
fi

if [ -z "$METHOD" ]; then
  warn "80 端口被占用，而且没找到可以借用的网站目录"
  say ""
  say "这种情况有两条路（选一条）："
  say "  1) 手动告诉我网站目录（那个目录要能通过 http://域名/.well-known/ 访问到）："
  say "       bash $0 $DOMAIN --webroot /网站根目录"
  say "  2) 用项目自带的证书功能（DNS 方式，不占 80）："
  say "       在管理台「证书」页填一次服务商密钥，就能签，还支持通配符"
  say ""
  exit 1
fi

say ""
say "域名    $DOMAIN"
say "方式    $([ "$METHOD" = standalone ] && echo '80 端口临时验证（签完就撤）' || echo "借用现有网站目录：$WEBROOT_FOUND")"
say "存放    $CERT_DIR"
[ "$STAGING" = 1 ] && say "模式    测试环境（证书浏览器不认，只验证流程）"
say ""

# ---------- 邮箱（可选，不需要也能签）----------
# 以前强制要邮箱，其实 Let's Encrypt 不强制；给空就注册一个不带邮箱的账户。

# ============================================================================
# 签证书（acme.sh，跑在临时容器里，不往宿主机装东西）
# ============================================================================
ACME_IMAGE="${ACME_IMAGE:-neilpang/acme.sh:latest}"
ACME_HOME_DIR="$ROOT_DIR/_certs/.acme"
mkdir -p "$ACME_HOME_DIR"
ACME_VOL=(-v "$ACME_HOME_DIR:/acme.sh")

info "准备 acme.sh"
docker image inspect "$ACME_IMAGE" >/dev/null 2>&1 || docker pull "$ACME_IMAGE" >/dev/null 2>&1 ||
  die "拉不到 $ACME_IMAGE（检查网络或换镜像源）"

ACME_SERVER_NAME="letsencrypt"
[ "$STAGING" = 1 ] && ACME_SERVER_NAME="letsencrypt_test"
issue_args=(--issue --server "$ACME_SERVER_NAME" --keylength ec-256)
[ -n "$EMAIL" ] && issue_args+=(--accountemail "$EMAIL")
[ "$VERBOSE" = 1 ] && issue_args+=(--debug)

info "开始签发（1~3 分钟）"
case "$METHOD" in
  standalone)
    docker run --rm --name "acme-$$" "${ACME_VOL[@]}" -p 80:80 "$ACME_IMAGE" \
      "${issue_args[@]}" --standalone -d "$DOMAIN" || die "签发失败（看上面的原因；80 端口要能从公网访问）"
    ;;
  webroot)
    docker run --rm --name "acme-$$" "${ACME_VOL[@]}" -v "$WEBROOT_FOUND:/www" "$ACME_IMAGE" \
      "${issue_args[@]}" -w /www -d "$DOMAIN" || die "签发失败（这个目录必须能通过 http://$DOMAIN/.well-known/ 访问）"
    ;;
esac

info "安装到 $CERT_DIR"
install_args=(--install-cert --ecc -d "$DOMAIN"
  --key-file "/out/privkey.pem" --fullchain-file "/out/fullchain.pem")
[ "$METHOD" = standalone ] && install_args+=(--reloadcmd "true")
docker run --rm --name "acme-inst-$$" "${ACME_VOL[@]}" -v "$CERT_DIR:/out" "$ACME_IMAGE" \
  "${install_args[@]}" >/dev/null 2>&1 || die "导出证书失败"

[ -s "$CERT_DIR/fullchain.pem" ] && [ -s "$CERT_DIR/privkey.pem" ] || die "证书文件没生成出来"
chmod 600 "$CERT_DIR/privkey.pem" 2>/dev/null || true

expires="$(openssl x509 -noout -enddate -in "$CERT_DIR/fullchain.pem" | sed 's/^notAfter=//')"
expires_iso="$(date -u -d "$expires" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$expires")"
cat > "$CERT_DIR/meta.json" <<EOF
{"domain":"$DOMAIN","method":"$METHOD","server":"$([ "$STAGING" = 1 ] && echo letsencrypt_test || echo letsencrypt)","expiresAt":"$expires_iso","issuedBy":"cert.sh $VERSION"}
EOF

ok "签发成功"
say "  证书    $CERT_DIR/fullchain.pem"
say "  私钥    $CERT_DIR/privkey.pem"
say "  有效期至 $expires_iso"
say ""
fi

# ============================================================================
# 装到项目里（目前支持 emby-proxy-manager 这类 data/certs/<代理名>/ 的结构）
# ============================================================================
[ "$NO_INSTALL" = 1 ] && exit 0

saw_project=0
for p in "$ROOT_DIR"/*/; do
  [ -f "$p/docker-compose.yml" ] || continue
  [ -d "$p/data/certs" ] || continue
  saw_project=1
done

if [ "$saw_project" = 1 ] && [ -n "$TTY_FD" ]; then
  say "已安装的项目里能直接用这张证书的有："
  names=()
  for p in "$ROOT_DIR"/*/; do
    [ -f "$p/docker-compose.yml" ] || continue
    [ -d "$p/data/certs" ] || continue
    names+=("$(basename "$p")")
    say "  $((${#names[@]}))  ${names[-1]}"
  done
  ask "要装进哪个项目？（直接回车=不装，先放着）" ""
  choice="$REPLY"
  if [ -n "$choice" ]; then
    case "$choice" in
      [0-9]*) idx="$((choice - 1))"; proj="${names[$idx]:-}" ;;
      *)      proj="$choice" ;;
    esac
    target="$ROOT_DIR/$proj/data/certs"
    if [ -z "${proj:-}" ] || [ ! -d "$target" ]; then
      warn "没找到这个项目，证书留在了 $CERT_DIR"
    else
      say ""
      say "  证书要挂在哪个代理名下？（就是管理台「代理」页里的名字，例如 emby）"
      ask "代理名" ""
      pname="$REPLY"
      if [ -n "$pname" ]; then
        mkdir -p "$target/$pname"
        cp -f "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "$target/$pname/"
        chmod 600 "$target/$pname/privkey.pem" 2>/dev/null || true
        cat > "$target/$pname/meta.json" <<EOF
{"domain":"$DOMAIN","provider":"manual","wildcard":false,"via":"cert.sh","expiresAt":"$expires_iso"}
EOF
        ok "已放进 $proj 的 $pname 名下"
        if docker compose -f "$ROOT_DIR/$proj/docker-compose.yml" --project-directory "$ROOT_DIR/$proj" ps --status running >/dev/null 2>&1; then
          docker exec "$proj" sh -c 'node /app/scripts/generate.js' >/dev/null 2>&1 &&
            docker exec "$proj" nginx -s reload >/dev/null 2>&1 &&
            ok "配置已重新生成并生效" || warn "请在管理台「证书」页点一次「重新签发」或重启容器让它生效"
        fi
      fi
    fi
  fi
fi

say ""
say "续期提醒：证书 30 天内到期前跑一次"
say "  bash cert.sh --renew --dir $ROOT_DIR"
say "想全自动就加一条定时任务（每天 3 点检查）："
say "  (crontab -l 2>/dev/null; echo '0 3 * * * bash $(cd "$(dirname "$0")" && pwd)/cert.sh --renew --dir $ROOT_DIR >/var/log/cert-renew.log 2>&1') | crontab -"
