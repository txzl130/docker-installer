#!/usr/bin/env bash
# ============================================================
#  gateway.sh —— HTTPS 统一入口（一个容器独占 443，按域名分给多个项目）
#
#  解决的问题：一台机器上 443 只能被一个程序占用。装了第二个项目就冲突。
#  做法：起一个很小的 nginx 容器专门占 443，按域名（SNI/Host）把请求转发到
#        各项目自己的内部 HTTPS 端口（127.0.0.1:8843、8844 …）。
#
#  用法：
#    sudo bash gateway.sh setup                      建好并启动入口（可重复执行）
#    sudo bash gateway.sh add <域名> <上游>           加一条转发
#        例：bash gateway.sh add emby.abc.com https://127.0.0.1:8843
#            上游省略协议时默认 http://
#    sudo bash gateway.sh add emby.abc.com            不写上游 → 列出本机在听的回环端口让你选
#    sudo bash gateway.sh list                       看现有转发和证书剩余天数
#    sudo bash gateway.sh rm <域名>                   删掉一条转发
#    sudo bash gateway.sh cert <域名>                 顺手签/续这张证书（调用 cert.sh）
#    sudo bash gateway.sh reload                     改了配置后重载（add/rm 会自动做）
#    sudo bash gateway.sh status                     容器和 443 监听状态
#    sudo bash gateway.sh down                       停掉入口（443 释放）
#
#  目录：<根>/_gateway/       入口自身的 compose、配置、缓存、日志
#        <根>/_certs/<域名>/  证书（cert.sh 签的，只读挂进入口）
#
#  ⚠️ 入口只占 443，不占 80 —— 80 留给 cert.sh 做 HTTP 校验。
# ============================================================
set -euo pipefail
VERSION="1.0.0"

ROOT_DIR="${GATEWAY_ROOT:-/opt/ysf/docker}"
GW_DIR=""
CONTAINER="https-gateway"
IMAGE="${GATEWAY_IMAGE:-nginx:1.27-alpine}"
HTTPS_PORT="${GATEWAY_PORT:-443}"
VERBOSE=0

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'
[ -t 1 ] || { c_red=; c_grn=; c_yel=; c_dim=; c_reset=; }

info() { printf '%s==>%s %s\n' "$c_dim" "$c_reset" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
die()  { printf '%s[xx]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

# ---- 交互（只写 stderr，读 /dev/tty；绝不能用数字 0 当 fd，否则 shell 会当文件名） ----
TTY_FD=""
if ( : >/dev/tty ) 2>/dev/null; then TTY_FD=/dev/tty
elif [ -t 0 ]; then TTY_FD=/dev/stdin; fi

ask() { # $1=提示 $2=默认值 → REPLY
  local ans=""
  if [ -n "$TTY_FD" ]; then
    printf '%s [%s]: ' "$1" "$2" >&2
    IFS= read -r ans < "$TTY_FD" || ans=""
  fi
  [ -z "$ans" ] && ans="$2"
  REPLY="$ans"
}

need_docker() { command -v docker >/dev/null 2>&1 || die "没有 docker，先装 Docker"; }

# 域名 → 配置文件名（域名本身是安全的，但统一成小写）
safe_name() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9.-]/_/g'; }

normalize_upstream() { # 补协议
  local u="$1"
  case "$u" in
    http://*|https://*) printf '%s' "$u" ;;
    *) printf 'http://%s' "$u" ;;
  esac
}

cert_files() { printf '%s/_certs/%s' "$ROOT_DIR" "$1"; }

cert_days_left() { # $1=域名 → 天数（没有证书输出 0）
  local crt; crt="$(cert_files "$1")/fullchain.pem"
  [ -s "$crt" ] || { printf '0'; return; }
  local end epoch now
  end="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  [ -n "$end" ] || { printf '0'; return; }
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [ "$epoch" -gt 0 ] || { printf '0'; return; }
  printf '%s' "$(( (epoch - now) / 86400 ))"
}

write_default_conf() {
  cat > "$GW_DIR/conf.d/00-default.conf" <<'EOF'
# 由 gateway.sh 生成，请勿手改
# WebSocket 升级映射
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
server {
    listen 443 ssl default_server;
    server_name _;
    # 没配置的域名直接断开（不暴露任何信息，也不需要证书）
    ssl_reject_handshake on;
}
EOF
}

write_route_conf() { # $1=域名 $2=上游
  local domain="$1" upstream="$2" f
  f="$GW_DIR/conf.d/$(safe_name "$domain").conf"
  local cf; cf="$(cert_files "$domain")"
  {
    printf '# 由 gateway.sh 生成：%s → %s（请勿手改，改的话用 gateway.sh 重加）\n' "$domain" "$upstream"
    printf 'server {\n'
    printf '    listen %s ssl;\n' "$HTTPS_PORT"
    printf '    server_name %s;\n' "$domain"
    printf '    ssl_certificate     /certs/%s/fullchain.pem;\n' "$domain"
    printf '    ssl_certificate_key /certs/%s/privkey.pem;\n' "$domain"
    printf '    ssl_protocols TLSv1.2 TLSv1.3;\n'
    printf '    add_header Strict-Transport-Security "max-age=31536000" always;\n'
    printf '    add_header X-Content-Type-Options nosniff always;\n'
    printf '    client_max_body_size 0;\n'
    printf '    location / {\n'
    printf '        proxy_pass %s;\n' "$upstream"
    printf '        proxy_http_version 1.1;\n'
    printf '        proxy_set_header Host $host;\n'
    printf '        proxy_set_header X-Real-IP $remote_addr;\n'
    printf '        proxy_set_header X-Forwarded-For $remote_addr;\n'
    printf '        proxy_set_header X-Forwarded-Proto https;\n'
    printf '        proxy_set_header Upgrade $http_upgrade;\n'
    printf '        proxy_set_header Connection $connection_upgrade;\n'
    printf '        proxy_buffering off;\n'
    printf '        proxy_request_buffering off;\n'
    printf '        proxy_read_timeout 3600s;\n'
    printf '        proxy_send_timeout 3600s;\n'
    printf '    }\n'
    printf '}\n'
  } > "$f"
  # 记住这条路由（list / rm / 重装后重建都靠它）
  printf 'DOMAIN=%s\nUPSTREAM=%s\n' "$domain" "$upstream" > "$GW_DIR/routes/$(safe_name "$domain").route"
}

compose_file() {
  cat > "$GW_DIR/docker-compose.yml" <<EOF
# 由 gateway.sh 生成（HTTPS 统一入口）
services:
  gateway:
    image: $IMAGE
    pull_policy: missing
    container_name: $CONTAINER
    restart: unless-stopped
    # host 网络：直接监听宿主机 443，转发也用 127.0.0.1
    network_mode: host
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./cache:/var/cache/nginx
      - ./logs:/var/log/nginx
      - $ROOT_DIR/_certs:/certs:ro
    healthcheck:
      test: ["CMD-SHELL", "nginx -t >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

# 把所有 routes/*.route 重新渲染成 conf.d
render_all() {
  write_default_conf
  local any=0 r
  for r in "$GW_DIR"/routes/*.route; do
    [ -e "$r" ] || continue
    local d u
    d="$(sed -n 's/^DOMAIN=//p' "$r" | head -1)"
    u="$(sed -n 's/^UPSTREAM=//p' "$r" | head -1)"
    [ -n "$d" ] && [ -n "$u" ] || continue
    if [ "$(cert_days_left "$d")" -le 0 ]; then
      warn "$d 还没有证书，跳过（先跑：sudo bash $(dirname "${BASH_SOURCE[0]}")/cert.sh $d）"
      continue
    fi
    write_route_conf "$d" "$u"
    any=1
  done
  [ "$any" = 0 ] && info "还没有任何转发（用 gateway.sh add 域名 上游 添加）"
  return 0
}

container_up() {
  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"
}

reload_gw() {
  if container_up; then
    docker exec "$CONTAINER" nginx -t 2>&1 | tail -3 || die "nginx 配置有问题，上面是报错（改完 routes 再跑 reload）"
    docker exec "$CONTAINER" nginx -s reload >/dev/null
    ok "已重载"
  else
    warn "入口容器没在跑，先跑一次：sudo bash $0 setup"
  fi
}

cmd_setup() {
  need_docker
  [ -d "$ROOT_DIR" ] || mkdir -p "$ROOT_DIR"
  GW_DIR="$ROOT_DIR/_gateway"
  mkdir -p "$GW_DIR"/{conf.d,routes,cache,logs}
  mkdir -p "$ROOT_DIR/_certs"

  # 443 被别的程序占着？先看清楚再决定
  if ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$HTTPS_PORT\$"; then
    if container_up; then
      info "443 已经由入口容器占用（正常）"
    else
      local owner; owner="$(ss -ltnp 2>/dev/null | grep -E "[:.]$HTTPS_PORT " | head -1)"
      warn "端口 $HTTPS_PORT 现在被别的程序占用："
      printf '    %s\n' "${owner:-未知}" >&2
      die "先把那个程序停掉或改成别的端口，再跑 setup（否则入口起不来）"
    fi
  fi

  compose_file
  render_all
  ( cd "$GW_DIR" && docker compose up -d >/dev/null 2>&1 ) || die "入口容器启动失败，看：cd $GW_DIR && docker compose logs"
  sleep 2
  docker exec "$CONTAINER" nginx -t >/dev/null 2>&1 || die "nginx 配置检查失败，看：docker logs $CONTAINER"
  ok "入口已启动：$GW_DIR（容器 $CONTAINER，占用 $HTTPS_PORT）"
  cmd_list
}

pick_port() { # 列出本机回环监听端口，让用户挑一个
  local ports p
  ports="$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -E '^(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\*):[0-9]+$' \
           | sed 's/.*://' | sort -n -u | grep -vE "^($HTTPS_PORT|80|8080)\$" | tr '\n' ' ')"
  printf '本机正在监听的端口（挑一个作为上游）：%s\n' "${ports:-无}" >&2
  ask "上游地址（例如 https://127.0.0.1:8843）" ""
  [ -n "$REPLY" ] || die "没给上游地址"
  normalize_upstream "$REPLY"
}

cmd_add() {
  need_docker
  local domain="${1:-}" upstream="${2:-}"
  [ -n "$domain" ] || die "用法：gateway.sh add <域名> [上游]"
  [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "域名不合法：$domain"
  [ -n "$upstream" ] || upstream="$(pick_port)"
  upstream="$(normalize_upstream "$upstream")"
  GW_DIR="$ROOT_DIR/_gateway"
  [ -d "$GW_DIR" ] || die "入口还没装，先跑：sudo bash $0 setup"
  local days; days="$(cert_days_left "$domain")"
  if [ "$days" -le 0 ]; then
    die "域名 $domain 还没有证书（$ROOT_DIR/_certs/$domain/）。先签：sudo bash $(dirname "${BASH_SOURCE[0]}")/cert.sh $domain"
  fi
  write_route_conf "$domain" "$upstream"
  ok "已添加：$domain → $upstream（证书剩 $days 天）"
  reload_gw
  printf '\n访问地址：https://%s\n' "$domain"
}

cmd_rm() {
  local domain="${1:-}"
  [ -n "$domain" ] || die "用法：gateway.sh rm <域名>"
  GW_DIR="$ROOT_DIR/_gateway"
  local sn; sn="$(safe_name "$domain")"
  rm -f "$GW_DIR/routes/$sn.route" "$GW_DIR/conf.d/$sn.conf"
  ok "已删除 $domain"
  reload_gw
}

cmd_list() {
  GW_DIR="$ROOT_DIR/_gateway"
  local r found=0
  printf '%-32s %-30s %s\n' "域名" "上游" "证书"
  for r in "$GW_DIR"/routes/*.route; do
    [ -e "$r" ] || continue
    local d u days
    d="$(sed -n 's/^DOMAIN=//p' "$r" | head -1)"
    u="$(sed -n 's/^UPSTREAM=//p' "$r" | head -1)"
    days="$(cert_days_left "$d")"
    printf '%-32s %-30s %s\n' "$d" "$u" "$([ "$days" -gt 0 ] && echo "剩 $days 天" || echo "无证书")"
    found=1
  done
  [ "$found" = 0 ] && info "还没有任何转发"
  return 0
}

cmd_cert() {
  local domain="${1:-}"
  [ -n "$domain" ] || die "用法：gateway.sh cert <域名>"
  local d; d="$(dirname "${BASH_SOURCE[0]}")"
  [ -f "$d/cert.sh" ] || die "找不到 $d/cert.sh（它应该在安装根目录）"
  bash "$d/cert.sh" "$domain" --dir "$ROOT_DIR" --no-install
}

cmd_status() {
  GW_DIR="$ROOT_DIR/_gateway"
  echo "根目录   $ROOT_DIR"
  echo "入口目录 $GW_DIR"
  if container_up; then
    echo "容器     $(docker ps --filter "name=^${CONTAINER}$" --format '{{.Status}}')"
  else
    echo "容器     未运行"
  fi
  echo -n "443 监听 "
  ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -E "[:.]$HTTPS_PORT\$" || echo "无"
  echo
  cmd_list
}

cmd_down() {
  GW_DIR="$ROOT_DIR/_gateway"
  [ -d "$GW_DIR" ] || die "入口还没装"
  ( cd "$GW_DIR" && docker compose down --remove-orphans ) || true
  ok "入口已停止，$HTTPS_PORT 释放"
}

# ---- 参数解析 ----
CMD="setup"
[ $# -gt 0 ] && { CMD="$1"; shift; }
case "$CMD" in
  setup|init)         cmd_setup "$@" ;;
  add)                cmd_add "$@" ;;
  rm|del|remove)      cmd_rm "$@" ;;
  list|ls)            cmd_list "$@" ;;
  cert)               cmd_cert "$@" ;;
  reload)             GW_DIR="$ROOT_DIR/_gateway"; reload_gw ;;
  status)             cmd_status "$@" ;;
  down|stop)          cmd_down "$@" ;;
  -h|--help|help)     usage ;;
  -v|--verbose)       VERBOSE=1; usage ;;
  *)                  die "未知命令：$CMD（用 --help 看用法）" ;;
esac
