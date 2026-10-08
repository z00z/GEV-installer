#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# God's Eye View — Hostinger Traefik one-click installer
# Fresh-VPS / fresh-install edition
#
# Supported Hostinger Traefik layouts:
#   1) Traefik running with network_mode=host
#   2) Hostinger's shared external "traefik-proxy" network
#
# Public access:
#   HTTPS + Traefik BasicAuth
#
# God's Eye View:
#   Official upstream source
#   GEV itself binds ONLY to 127.0.0.1:4173
#
# POWER UP:
#   Provider Settings remains usable remotely behind auth
#   through a tightly-scoped loopback adapter.
# ============================================================

APP_ROOT="/opt/gods-eye-view"
SRC_DIR="$APP_ROOT/app"
STATE_DIR="$APP_ROOT/state"

REPO="https://github.com/bilawalsidhu/gods-eye-view.git"
GEV_REF="main"
EXPECTED_GEV_VERSION="0.2.1"

NODE_IMAGE="node:24.21.0-bookworm-slim"
RUNTIME_IMAGE="gods-eye-view-hosted:local"

APP_UID=1000
APP_GID=1000

CERT_RESOLVER="letsencrypt"
SHARED_TRAEFIK_NETWORK="traefik-proxy"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup_tmp() {
  rm -f "${TMP_TRAEFIK_LIST:-}" 2>/dev/null || true
}
trap cleanup_tmp EXIT

on_error() {
  local rc=$?
  printf '\n\033[1;31mInstaller stopped (exit %s).\033[0m\n' "$rc" >&2

  if [[ -d "$APP_ROOT" ]] && command -v docker >/dev/null 2>&1; then
    (
      cd "$APP_ROOT"
      docker compose ps 2>/dev/null || true
      docker compose logs --tail=120 gods-eye-view 2>/dev/null || true
    ) >&2
  fi

  exit "$rc"
}
trap on_error ERR


# ============================================================
# ROOT / FRESH-INSTALL GUARDS
# ============================================================

[[ ${EUID:-$(id -u)} -eq 0 ]] ||
  die "Run this installer as root."

command -v docker >/dev/null 2>&1 ||
  die "Docker is not installed. Start from Hostinger's Docker/Traefik VPS image."

docker compose version >/dev/null 2>&1 ||
  die "Docker Compose v2 is not available."

if [[ -e "$APP_ROOT/docker-compose.yml" ||
      -e "$APP_ROOT/app" ||
      -e "$APP_ROOT/.public-host" ]]
then
  die "An existing God's Eye View installation was found at:

$APP_ROOT

This public installer is intentionally fresh-install only.
Use a new VPS, or remove the old installation yourself after backing up any .env/API keys."
fi


# ============================================================
# MINIMAL HOST PREREQUISITES
# ============================================================

say "Installing prerequisites"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  git \
  ca-certificates \
  curl \
  apache2-utils \
  nano \
  iproute2 \
  >/dev/null


# ============================================================
# TRAEFIK DETECTION
#
# We support the two Hostinger layouts seen/documented:
#
# A) Host-network Traefik:
#      Traefik itself is network_mode=host and can reach Docker
#      bridge-container IPs directly.
#
# B) Shared bridge:
#      Traefik joins external network "traefik-proxy"; this app
#      joins the same network and labels it explicitly.
# ============================================================

say "Detecting the Hostinger Traefik deployment"

TMP_TRAEFIK_LIST="$(mktemp)"
: > "$TMP_TRAEFIK_LIST"

while IFS= read -r cid; do
  [[ -n "$cid" ]] || continue

  image="$(
    docker inspect "$cid" \
      --format '{{.Config.Image}}' \
      2>/dev/null || true
  )"

  image_lc="${image,,}"

  [[ "$image_lc" == *traefik* ]] || continue

  socket_mount="$(
    docker inspect "$cid" \
      --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}yes{{end}}{{end}}' \
      2>/dev/null || true
  )"

  [[ "$socket_mount" == "yes" ]] || continue

  name="$(
    docker inspect "$cid" \
      --format '{{.Name}}' \
      2>/dev/null | sed 's#^/##' || true
  )"

  network_mode="$(
    docker inspect "$cid" \
      --format '{{.HostConfig.NetworkMode}}' \
      2>/dev/null || true
  )"

  networks="$(
    docker inspect "$cid" \
      --format '{{range $name, $cfg := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
      2>/dev/null || true
  )"

  if [[ "$network_mode" == "host" ]]; then
    printf '%s|%s|host|\n' "$cid" "$name" >> "$TMP_TRAEFIK_LIST"
    continue
  fi

  if grep -Fxq "$SHARED_TRAEFIK_NETWORK" <<<"$networks"; then
    printf '%s|%s|shared|%s\n' \
      "$cid" "$name" "$SHARED_TRAEFIK_NETWORK" \
      >> "$TMP_TRAEFIK_LIST"
    continue
  fi

done < <(
  docker ps \
    --filter status=running \
    --format '{{.ID}}'
)

TRAEFIK_COUNT="$(wc -l < "$TMP_TRAEFIK_LIST" | tr -d ' ')"

(( TRAEFIK_COUNT >= 1 )) ||
  die "No compatible running Hostinger Traefik container was found.

Expected either:
  • a running Traefik container using host networking, or
  • a running Traefik container attached to the external '$SHARED_TRAEFIK_NETWORK' network,

with /var/run/docker.sock mounted.

Deploy/start Hostinger's Traefik template first."

if (( TRAEFIK_COUNT > 1 )); then
  printf '\nCompatible Traefik containers found:\n' >&2
  awk -F'|' '{printf "  - %s (%s)\n", $2, $3}' "$TMP_TRAEFIK_LIST" >&2

  die "More than one compatible Traefik instance is running.

A fresh Hostinger VPS should have one active Traefik instance.
Remove/stop duplicate Traefik projects and run the installer again."
fi

IFS='|' read -r TRAEFIK_CID TRAEFIK_CONTAINER TRAEFIK_MODE TRAEFIK_NETWORK \
  < "$TMP_TRAEFIK_LIST"

[[ -n "$TRAEFIK_CONTAINER" ]] ||
  die "Could not identify the active Traefik container."

if [[ "$TRAEFIK_MODE" == "shared" ]]; then
  docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1 ||
    die "Traefik reports the shared network '$TRAEFIK_NETWORK', but Docker cannot inspect it."
fi

TRAEFIK_CMD="$(
  docker inspect "$TRAEFIK_CID" \
    --format '{{range .Config.Cmd}}{{println .}}{{end}}' \
    2>/dev/null || true
)"

# These are the Hostinger conventions our labels rely on.
if [[ -n "$TRAEFIK_CMD" ]]; then
  if grep -q -- '--providers.docker.exposedbydefault=true' <<<"$TRAEFIK_CMD"; then
    warn "Traefik has exposedByDefault=true. The GEV service still declares traefik.enable=true and is protected by BasicAuth, but this is less strict than Hostinger's normal template."
  fi
fi

ok "Traefik detected: $TRAEFIK_CONTAINER ($TRAEFIK_MODE mode)"


# ============================================================
# HOSTINGER HOSTNAME
# ============================================================

normalize_host() {
  local value="${1:-}"

  value="${value,,}"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%.}"

  printf '%s' "$value"
}

valid_hostname() {
  local value="${1:-}"

  (( ${#value} <= 253 )) || return 1

  [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

detect_hostinger_base() {
  local candidate=""

  candidate="$(normalize_host "${TRAEFIK_HOST:-}")"
  if [[ "$candidate" =~ ^srv[0-9]+\.hstgr\.cloud$ ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  for candidate in \
    "$(hostname -f 2>/dev/null || true)" \
    "$(hostname 2>/dev/null || true)" \
    "$(cat /etc/hostname 2>/dev/null || true)"
  do
    candidate="$(normalize_host "$candidate")"

    if [[ "$candidate" =~ ^srv[0-9]+\.hstgr\.cloud$ ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  if [[ -d /docker ]]; then
    while IFS= read -r candidate; do
      candidate="$(normalize_host "$candidate")"

      if [[ "$candidate" =~ ^srv[0-9]+\.hstgr\.cloud$ ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done < <(
      grep -RhsE '^[[:space:]]*TRAEFIK_HOST=' \
        /docker/*/.env \
        /docker/*/*/.env \
        2>/dev/null \
        | sed -E 's/^[[:space:]]*TRAEFIK_HOST[[:space:]]*=[[:space:]]*//' \
        | tr -d '"\047' \
        || true
    )
  fi

  candidate="$(
    docker inspect "$TRAEFIK_CID" 2>/dev/null \
      | grep -oE 'srv[0-9]+\.hstgr\.cloud' \
      | head -n1 \
      || true
  )"

  candidate="$(normalize_host "$candidate")"

  if [[ "$candidate" =~ ^srv[0-9]+\.hstgr\.cloud$ ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  return 1
}

if [[ -n "${GEV_DOMAIN:-}" ]]; then
  DOMAIN="$(normalize_host "$GEV_DOMAIN")"

  valid_hostname "$DOMAIN" ||
    die "GEV_DOMAIN is not a valid hostname: $DOMAIN"

  HOST_MODE="custom domain"

else
  BASE_HOST="$(detect_hostinger_base || true)"

  [[ -n "$BASE_HOST" ]] ||
    die "Could not detect the Hostinger VPS hostname (expected srvNNNNNN.hstgr.cloud).

If you intentionally changed the VPS hostname, run with a domain you control:

GEV_DOMAIN=gev.example.com bash install-gev.sh"

  RANDOM_SUFFIX="$(
    od -An -N4 -tx1 /dev/urandom \
      | tr -d ' \n'
  )"

  [[ "$RANDOM_SUFFIX" =~ ^[0-9a-f]{8}$ ]] ||
    die "Could not generate the Hostinger hostname suffix."

  DOMAIN="gev-${RANDOM_SUFFIX}.${BASE_HOST}"

  valid_hostname "$DOMAIN" ||
    die "Generated Hostinger hostname is invalid: $DOMAIN"

  HOST_MODE="Hostinger wildcard hostname"
fi

mkdir -p "$APP_ROOT"
chmod 700 "$APP_ROOT"

printf '%s\n' "$DOMAIN" > "$APP_ROOT/.public-host"
chmod 600 "$APP_ROOT/.public-host"

say "Checking public DNS / Hostinger wildcard routing"

DNS_OK=0

for _ in $(seq 1 12); do
  if getent ahostsv4 "$DOMAIN" >/dev/null 2>&1; then
    DNS_OK=1
    break
  fi

  sleep 5
done

(( DNS_OK == 1 )) ||
  die "The public hostname does not resolve:

$DOMAIN

For a custom GEV_DOMAIN, create its DNS record first.
For a Hostinger hostname, verify the VPS hostname/wildcard DNS is active."

# Before our router exists, a reachable Traefik normally returns a redirect
# or a not-found response. The exact status is not important; a real HTTP
# response proves DNS reaches the VPS edge instead of timing out.
HTTP_PRECHECK="$(
  curl \
    -sS \
    --connect-timeout 8 \
    --max-time 20 \
    -o /dev/null \
    -w '%{http_code}' \
    "http://${DOMAIN}/" \
    2>/dev/null \
    || true
)"

[[ "$HTTP_PRECHECK" =~ ^[1-5][0-9][0-9]$ ]] ||
  die "DNS resolves, but HTTP traffic did not reach a web server for:

http://${DOMAIN}/

Check Hostinger networking/firewall and the Traefik project before continuing."

ok "Public hostname is reachable: $DOMAIN"


# ============================================================
# LOGIN CREDENTIALS
# ============================================================

printf '\nGod\x27s Eye View — secure Hostinger deployment\n'
printf '%s\n' '---------------------------------------------'

while :; do
  printf 'Login username [admin]: ' >/dev/tty
  IFS= read -r AUTH_USER </dev/tty

  AUTH_USER="${AUTH_USER:-admin}"

  [[ "$AUTH_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && break

  printf 'Use 1-64 letters, numbers, dots, underscores or hyphens.\n' >/dev/tty
done

while :; do
  printf 'Login password (12-64 bytes): ' >/dev/tty
  IFS= read -rs AUTH_PASS </dev/tty

  printf '\nConfirm password: ' >/dev/tty
  IFS= read -rs AUTH_CONFIRM </dev/tty
  printf '\n' >/dev/tty

  if [[ "$AUTH_PASS" != "$AUTH_CONFIRM" ]]; then
    printf 'Passwords do not match. Try again.\n' >/dev/tty
    continue
  fi

  PASS_BYTES="$(
    printf '%s' "$AUTH_PASS" \
      | wc -c \
      | tr -d ' '
  )"

  if (( PASS_BYTES < 12 || PASS_BYTES > 64 )); then
    printf 'Use a password between 12 and 64 bytes.\n' >/dev/tty
    continue
  fi

  break
done

AUTH_PAIR="$(
  printf '%s\n' "$AUTH_PASS" \
    | htpasswd -niB -C 10 "$AUTH_USER"
)"

AUTH_ESCAPED="$(
  printf '%s' "$AUTH_PAIR" \
    | sed 's/\$/\$\$/g'
)"

ROUTER_SUFFIX="$(
  printf '%s' "$DOMAIN" \
    | sha256sum \
    | cut -c1-10
)"

ROUTER_ID="gev-${ROUTER_SUFFIX}"


# ============================================================
# OFFICIAL GEV SOURCE
# ============================================================

say "Resolving and cloning official God's Eye View source"

RESOLVED_GEV_SHA="$(
  git ls-remote "$REPO" "refs/heads/${GEV_REF}" \
    | awk 'NR==1{print $1}'
)"

[[ "$RESOLVED_GEV_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  die "Could not resolve the official God's Eye View ${GEV_REF} revision."

mkdir -p \
  "$STATE_DIR/cache" \
  "$STATE_DIR/logs"

git clone \
  --depth=1 \
  --branch "$GEV_REF" \
  "$REPO" \
  "$SRC_DIR"

[[ -f "$SRC_DIR/package.json" ]] ||
  die "GEV checkout is missing package.json."

[[ -f "$SRC_DIR/package-lock.json" ]] ||
  die "GEV checkout is missing package-lock.json."

[[ -f "$SRC_DIR/.env.example" ]] ||
  die "GEV checkout is missing .env.example."

[[ -f "$SRC_DIR/src/keySetupCore.mjs" ]] ||
  die "GEV checkout is missing src/keySetupCore.mjs."

[[ -f "$SRC_DIR/src/localRequestGate.mjs" ]] ||
  die "GEV checkout is missing src/localRequestGate.mjs."

UPSTREAM_COMMIT="$(
  git \
    -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" \
    rev-parse HEAD
)"

[[ "$UPSTREAM_COMMIT" == "$RESOLVED_GEV_SHA" ]] ||
  die "God's Eye View main changed while the installer was cloning it.

Resolved first: $RESOLVED_GEV_SHA
Cloned:         $UPSTREAM_COMMIT

Run the installer again so one exact upstream revision is validated end-to-end."

UPSTREAM_VERSION="$(
  sed -nE \
    's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    "$SRC_DIR/package.json" \
    | head -n1
)"

[[ "$UPSTREAM_VERSION" == "$EXPECTED_GEV_VERSION" ]] ||
  die "This installer was audited for God's Eye View $EXPECTED_GEV_VERSION.

The cloned source reports version:

${UPSTREAM_VERSION:-unknown}

The installer has stopped before deployment so a newer upstream security/runtime change is not silently exposed."

EXPECTED_PROXY_SIGNALS="cf-connecting-ip cf-ray forwarded via x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-proto x-real-ip"

ACTUAL_PROXY_SIGNALS="$(
  sed -n \
    '/PROXY_SIGNALS = Object.freeze(\[/,/\]);/p' \
    "$SRC_DIR/src/localRequestGate.mjs" \
    | grep -oE "'[^']+'" \
    | tr -d "'" \
    | sort \
    | xargs \
    || true
)"

[[ "$ACTUAL_PROXY_SIGNALS" == "$EXPECTED_PROXY_SIGNALS" ]] ||
  die "GEV's reverse-proxy security policy has changed.

Expected:
$EXPECTED_PROXY_SIGNALS

Found:
${ACTUAL_PROXY_SIGNALS:-none}

The installer stopped rather than bypassing an unaudited security policy."

grep -Fq 'LOOPBACK_ADDRESSES' "$SRC_DIR/src/keySetupCore.mjs" ||
  die "GEV Provider Settings loopback policy changed."

grep -Fq 'Provider Settings answers only local hostnames' "$SRC_DIR/src/keySetupCore.mjs" ||
  die "GEV Provider Settings Host policy changed."

grep -Fq 'Provider Settings requires an exact local Origin' "$SRC_DIR/src/keySetupCore.mjs" ||
  die "GEV Provider Settings Origin policy changed."

grep -Fq "clientExposed: true" "$SRC_DIR/src/keySetupCore.mjs" ||
  die "GEV Provider Settings registry shape changed unexpectedly."

ok "GEV compatibility contract matches audited version $EXPECTED_GEV_VERSION"


# ============================================================
# GEV CONFIG
# ============================================================

cp "$SRC_DIR/.env.example" "$SRC_DIR/.env"

# OpenSky "auto" gives keyless anonymous service now and automatically uses
# OAuth later if the user enters credentials in POWER UP.
if grep -Eq '^[[:space:]]*OPENSKY_AUTH_MODE=' "$SRC_DIR/.env"; then
  sed -i -E \
    's/^[[:space:]]*OPENSKY_AUTH_MODE=.*/OPENSKY_AUTH_MODE=auto/' \
    "$SRC_DIR/.env"
else
  printf '\nOPENSKY_AUTH_MODE=auto\n' >> "$SRC_DIR/.env"
fi

chown -R "$APP_UID:$APP_GID" "$SRC_DIR" "$STATE_DIR"

chmod 700 \
  "$SRC_DIR" \
  "$STATE_DIR" \
  "$STATE_DIR/cache" \
  "$STATE_DIR/logs"

chmod 600 "$SRC_DIR/.env"


# ============================================================
# PRIVATE EDGE TOKEN
# ============================================================

EDGE_TOKEN="$(
  od -An -N32 -tx1 /dev/urandom \
    | tr -d ' \n'
)"

[[ "$EDGE_TOKEN" =~ ^[0-9a-f]{64}$ ]] ||
  die "Could not generate the private Traefik edge token."


# ============================================================
# NGINX LOOPBACK ADAPTER
# ============================================================

cat > "$APP_ROOT/nginx.conf" <<'EOF'
pid /tmp/gev-nginx/nginx.pid;
error_log /dev/stderr warn;

events {}

http {
  access_log off;

  map_hash_bucket_size 512;
  server_names_hash_bucket_size 512;

  client_body_temp_path /tmp/gev-nginx/client_body;
  proxy_temp_path /tmp/gev-nginx/proxy;
  fastcgi_temp_path /tmp/gev-nginx/fastcgi;
  uwsgi_temp_path /tmp/gev-nginx/uwsgi;
  scgi_temp_path /tmp/gev-nginx/scgi;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  # Browsers see HTTPS at Traefik; GEV sees local HTTP.
  # Translate only our exact public Origin so normal same-origin
  # provider routes continue to pass GEV's own gate.
  map $http_origin $gev_app_origin {
    default $http_origin;
    "https://__DOMAIN__" "http://__DOMAIN__";
  }

  # POWER UP is stricter: saving credentials must originate from
  # this exact authenticated public page.
  map $http_origin $gev_setup_origin_state {
    default bad;
    "" none;
    "https://__DOMAIN__" same;
  }

  server {
    listen 8080;
    server_name __DOMAIN__;

    client_max_body_size 32m;

    # Only our Traefik middleware knows/injects this token.
    if ($http_x_gev_edge_token != "__EDGE_TOKEN__") {
      return 403;
    }

    if ($host != "__DOMAIN__") {
      return 444;
    }

    # Provider Settings status
    location = /api/setup/status {
      if ($request_method != GET) {
        return 405;
      }

      if ($gev_setup_origin_state = bad) {
        return 403;
      }

      proxy_pass http://127.0.0.1:4173;
      proxy_http_version 1.1;

      # Make this a genuine loopback/local-host request as required
      # by the upstream Provider Settings admission gate.
      proxy_set_header Host "localhost:4173";
      proxy_set_header Origin "http://localhost:4173";

      proxy_set_header Authorization "";
      proxy_set_header Proxy-Authorization "";
      proxy_set_header X-GEV-Edge-Token "";

      proxy_set_header Forwarded "";
      proxy_set_header Via "";
      proxy_set_header X-Forwarded-For "";
      proxy_set_header X-Forwarded-Host "";
      proxy_set_header X-Forwarded-Port "";
      proxy_set_header X-Forwarded-Proto "";
      proxy_set_header X-Real-IP "";
      proxy_set_header CF-Connecting-IP "";
      proxy_set_header CF-Ray "";

      # Also strip neighboring/common proxy/CDN identity headers.
      proxy_set_header X-Forwarded-Server "";
      proxy_set_header X-Forwarded-Scheme "";
      proxy_set_header X-Forwarded-Protocol "";
      proxy_set_header X-Forwarded-Ssl "";
      proxy_set_header True-Client-IP "";
      proxy_set_header CF-Connecting-IPv6 "";
      proxy_set_header CF-Visitor "";
      proxy_set_header CDN-Loop "";

      proxy_buffering off;
      proxy_request_buffering off;
      proxy_read_timeout 60s;
      proxy_send_timeout 60s;
    }

    # Provider Settings save
    location = /api/setup/keys {
      if ($request_method != POST) {
        return 405;
      }

      if ($gev_setup_origin_state != same) {
        return 403;
      }

      proxy_pass http://127.0.0.1:4173;
      proxy_http_version 1.1;

      proxy_set_header Host "localhost:4173";
      proxy_set_header Origin "http://localhost:4173";

      proxy_set_header Authorization "";
      proxy_set_header Proxy-Authorization "";
      proxy_set_header X-GEV-Edge-Token "";

      proxy_set_header Forwarded "";
      proxy_set_header Via "";
      proxy_set_header X-Forwarded-For "";
      proxy_set_header X-Forwarded-Host "";
      proxy_set_header X-Forwarded-Port "";
      proxy_set_header X-Forwarded-Proto "";
      proxy_set_header X-Real-IP "";
      proxy_set_header CF-Connecting-IP "";
      proxy_set_header CF-Ray "";

      proxy_set_header X-Forwarded-Server "";
      proxy_set_header X-Forwarded-Scheme "";
      proxy_set_header X-Forwarded-Protocol "";
      proxy_set_header X-Forwarded-Ssl "";
      proxy_set_header True-Client-IP "";
      proxy_set_header CF-Connecting-IPv6 "";
      proxy_set_header CF-Visitor "";
      proxy_set_header CDN-Loop "";

      proxy_buffering off;
      proxy_request_buffering off;
      proxy_read_timeout 60s;
      proxy_send_timeout 60s;
    }

    # Normal GEV app and provider APIs
    location / {
      proxy_pass http://127.0.0.1:4173;
      proxy_http_version 1.1;

      proxy_set_header Host $host;
      proxy_set_header Origin $gev_app_origin;

      # Vite/HMR/realtime WebSocket compatibility.
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;

      # Never leak HTTP BasicAuth credentials into GEV.
      proxy_set_header Authorization "";
      proxy_set_header Proxy-Authorization "";
      proxy_set_header X-GEV-Edge-Token "";

      # Current GEV security policy refuses reverse-proxy signals.
      proxy_set_header Forwarded "";
      proxy_set_header Via "";
      proxy_set_header X-Forwarded-For "";
      proxy_set_header X-Forwarded-Host "";
      proxy_set_header X-Forwarded-Port "";
      proxy_set_header X-Forwarded-Proto "";
      proxy_set_header X-Real-IP "";
      proxy_set_header CF-Connecting-IP "";
      proxy_set_header CF-Ray "";

      proxy_set_header X-Forwarded-Server "";
      proxy_set_header X-Forwarded-Scheme "";
      proxy_set_header X-Forwarded-Protocol "";
      proxy_set_header X-Forwarded-Ssl "";
      proxy_set_header True-Client-IP "";
      proxy_set_header CF-Connecting-IPv6 "";
      proxy_set_header CF-Visitor "";
      proxy_set_header CDN-Loop "";

      # Range, Sec-Fetch-* and ordinary request headers remain intact.
      proxy_buffering off;
      proxy_request_buffering off;

      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }
  }
}
EOF

sed -i \
  -e "s/__DOMAIN__/${DOMAIN}/g" \
  -e "s/__EDGE_TOKEN__/${EDGE_TOKEN}/g" \
  "$APP_ROOT/nginx.conf"


# ============================================================
# RUNTIME ENTRYPOINT
# ============================================================

cat > "$APP_ROOT/runtime-entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

cd /app

mkdir -p \
  /tmp/gev-nginx/client_body \
  /tmp/gev-nginx/proxy \
  /tmp/gev-nginx/fastcgi \
  /tmp/gev-nginx/uwsgi \
  /tmp/gev-nginx/scgi

nginx -t -c /etc/nginx/nginx.conf

node node_modules/vite/bin/vite.js \
  --host 127.0.0.1 \
  --port 4173 \
  --strictPort &

GEV_PID=$!

READY=0

for _ in $(seq 1 60); do
  if ! kill -0 "$GEV_PID" 2>/dev/null; then
    wait "$GEV_PID" || true
    printf 'GEV exited before becoming ready.\n' >&2
    exit 1
  fi

  if node -e \
    "fetch('http://127.0.0.1:4173/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
    >/dev/null 2>&1
  then
    READY=1
    break
  fi

  sleep 1
done

if (( READY != 1 )); then
  printf 'GEV did not become ready on 127.0.0.1:4173.\n' >&2
  kill -TERM "$GEV_PID" 2>/dev/null || true
  wait "$GEV_PID" 2>/dev/null || true
  exit 1
fi

nginx \
  -c /etc/nginx/nginx.conf \
  -g 'daemon off;' &

NGINX_PID=$!

cleanup() {
  trap - TERM INT
  kill -TERM "$NGINX_PID" "$GEV_PID" 2>/dev/null || true
  wait "$NGINX_PID" 2>/dev/null || true
  wait "$GEV_PID" 2>/dev/null || true
}

trap 'cleanup; exit 0' TERM INT

set +e
wait -n "$GEV_PID" "$NGINX_PID"
RC=$?
set -e

cleanup
exit "$RC"
EOF


# ============================================================
# HEALTHCHECK
# ============================================================

cat > "$APP_ROOT/healthcheck.mjs" <<'EOF'
import http from 'node:http';

const host = String(process.env.GEV_PUBLIC_HOST || '').trim();
const token = String(process.env.GEV_EDGE_TOKEN || '').trim();

if (!host || !token) process.exit(1);

const req = http.request(
  {
    hostname: '127.0.0.1',
    port: 8080,
    path: '/api/setup/status',
    method: 'GET',
    headers: {
      Host: host,
      Origin: `https://${host}`,
      'X-GEV-Edge-Token': token,
    },
  },
  (res) => {
    res.resume();
    res.on('end', () => process.exit(res.statusCode === 200 ? 0 : 1));
  },
);

req.setTimeout(4000, () => req.destroy(new Error('health timeout')));
req.on('error', () => process.exit(1));
req.end();
EOF


# ============================================================
# DOCKER IMAGE
# ============================================================

cat > "$APP_ROOT/.dockerignore" <<'EOF'
*
!Dockerfile
!nginx.conf
!runtime-entrypoint.sh
!healthcheck.mjs
EOF

cat > "$APP_ROOT/Dockerfile" <<EOF
FROM ${NODE_IMAGE}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash \
       nginx \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p \
       /tmp/gev-nginx/client_body \
       /tmp/gev-nginx/proxy \
       /tmp/gev-nginx/fastcgi \
       /tmp/gev-nginx/uwsgi \
       /tmp/gev-nginx/scgi \
    && chown -R node:node /tmp/gev-nginx

COPY --chown=node:node --chmod=600 \
  nginx.conf \
  /etc/nginx/nginx.conf

COPY --chown=node:node --chmod=755 \
  runtime-entrypoint.sh \
  /usr/local/bin/gev-runtime

COPY --chown=node:node --chmod=755 \
  healthcheck.mjs \
  /usr/local/bin/gev-healthcheck.mjs

USER node
WORKDIR /app

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/gev-runtime"]
EOF


# ============================================================
# COMPOSE — GENERATED FOR THE DETECTED TRAEFIK LAYOUT
# ============================================================

NETWORK_LABEL_BLOCK=""
SERVICE_NETWORK_BLOCK=""
TOP_NETWORK_BLOCK=""

if [[ "$TRAEFIK_MODE" == "shared" ]]; then
  NETWORK_LABEL_BLOCK="      - 'traefik.docker.network=${TRAEFIK_NETWORK}'"
  SERVICE_NETWORK_BLOCK="    networks:
      - ${TRAEFIK_NETWORK}"
  TOP_NETWORK_BLOCK="networks:
  ${TRAEFIK_NETWORK}:
    external: true"
else
  SERVICE_NETWORK_BLOCK="    networks:
      - gev-private"
  TOP_NETWORK_BLOCK="networks:
  gev-private:
    driver: bridge"
fi

cat > "$APP_ROOT/docker-compose.yml" <<EOF
services:

  gods-eye-view:

    build:
      context: .
      dockerfile: Dockerfile

    image: ${RUNTIME_IMAGE}
    container_name: gods-eye-view

    user: "${APP_UID}:${APP_GID}"
    working_dir: /app

    restart: unless-stopped
    init: true

    environment:
      HOME: /home/node

      HOST: 127.0.0.1
      PORT: 4173

      GEV_ALLOWED_HOSTS: ${DOMAIN}
      GEV_PUBLIC_HOST: ${DOMAIN}
      GEV_EDGE_TOKEN: ${EDGE_TOKEN}

      # Keep GEV's own sharing/tunnel modes off. Public access is
      # exclusively through this authenticated Traefik route.
      PINOKIO_SHARE_CLOUDFLARE: "false"
      PINOKIO_SHARE_LOCAL: "false"
      PINOKIO_SHARE_VAR: "__gev_sharing_disabled__"

      PUPPETEER_SKIP_DOWNLOAD: "true"

    volumes:
      - ./app:/app
      - gev-node-modules:/app/node_modules
      - ./state/cache:/app/.gev-cache
      - ./state/logs:/app/.gev-logs

    expose:
      - "8080"

${SERVICE_NETWORK_BLOCK}

    labels:
      - 'traefik.enable=true'
${NETWORK_LABEL_BLOCK}
      - 'traefik.http.services.${ROUTER_ID}.loadbalancer.server.port=8080'

      - 'traefik.http.routers.${ROUTER_ID}.rule=Host(\`${DOMAIN}\`)'
      - 'traefik.http.routers.${ROUTER_ID}.entrypoints=websecure'
      - 'traefik.http.routers.${ROUTER_ID}.service=${ROUTER_ID}'
      - 'traefik.http.routers.${ROUTER_ID}.tls=true'
      - 'traefik.http.routers.${ROUTER_ID}.tls.certresolver=${CERT_RESOLVER}'

      # Authenticate first; inject private internal marker second.
      - 'traefik.http.routers.${ROUTER_ID}.middlewares=${ROUTER_ID}-auth@docker,${ROUTER_ID}-edge@docker'

      - 'traefik.http.middlewares.${ROUTER_ID}-auth.basicauth.users=${AUTH_ESCAPED}'
      - 'traefik.http.middlewares.${ROUTER_ID}-auth.basicauth.removeheader=true'
      - 'traefik.http.middlewares.${ROUTER_ID}-auth.basicauth.realm=Gods Eye View'

      - 'traefik.http.middlewares.${ROUTER_ID}-edge.headers.customrequestheaders.X-GEV-Edge-Token=${EDGE_TOKEN}'

    healthcheck:
      test:
        [
          "CMD",
          "node",
          "/usr/local/bin/gev-healthcheck.mjs"
        ]
      interval: 10s
      timeout: 5s
      retries: 24
      start_period: 30s

    stop_grace_period: 20s


  gev-maintenance:

    image: ${NODE_IMAGE}
    user: "${APP_UID}:${APP_GID}"
    working_dir: /app

    environment:
      HOME: /home/node
      PUPPETEER_SKIP_DOWNLOAD: "true"

    volumes:
      - ./app:/app
      - gev-node-modules:/app/node_modules
      - ./state/cache:/app/.gev-cache
      - ./state/logs:/app/.gev-logs

    profiles:
      - maintenance


${TOP_NETWORK_BLOCK}


volumes:
  gev-node-modules:
EOF

chmod 600 \
  "$APP_ROOT/docker-compose.yml" \
  "$APP_ROOT/nginx.conf" \
  "$APP_ROOT/.dockerignore"

chmod 755 "$APP_ROOT/runtime-entrypoint.sh"

chmod 644 \
  "$APP_ROOT/healthcheck.mjs" \
  "$APP_ROOT/Dockerfile"


# ============================================================
# STATIC VALIDATION
# ============================================================

cd "$APP_ROOT"

say "Validating Docker Compose configuration"
docker compose config -q

if docker compose config \
  | grep -Eq 'published:|host_ip:'
then
  die "Safety check failed: generated Compose unexpectedly publishes a host port."
fi


# ============================================================
# BUILD / TEST OFFICIAL GEV
# ============================================================

say "Building the local runtime image"
docker compose build --pull gods-eye-view

say "Pulling the Node maintenance image"
docker compose pull gev-maintenance

say "Verifying the Node runtime version"

NODE_RUNTIME_VERSION="$(
  docker compose run \
    --rm \
    --no-deps \
    gev-maintenance \
    node -p 'process.versions.node'
)"

[[ "$NODE_RUNTIME_VERSION" =~ ^24\.([0-9]+)\.([0-9]+)$ ]] ||
  die "The selected Node image returned an unsupported runtime: ${NODE_RUNTIME_VERSION:-unknown}"

NODE_MINOR="${BASH_REMATCH[1]}"

(( NODE_MINOR >= 14 )) ||
  die "God's Eye View requires Node 24.14.0 or newer within the Node 24 line.

Detected: $NODE_RUNTIME_VERSION"

say "Preparing persistent npm/cache directories"

docker compose run \
  --rm \
  --no-deps \
  --user 0:0 \
  gev-maintenance \
  sh -lc \
  'mkdir -p /app/node_modules /app/.gev-cache /app/.gev-logs && chown -R 1000:1000 /app/node_modules /app/.gev-cache /app/.gev-logs'

say "Installing the exact locked npm dependency tree"

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm ci --no-audit --no-fund

say "Semantically verifying the GEV security gates this adapter depends on"

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  node --input-type=module -e '
import { admitKeySetupRequest } from "./src/keySetupCore.mjs";
import { admitSameSiteRequest, PROXY_SIGNALS } from "./src/localRequestGate.mjs";

const expected = [
  "forwarded",
  "via",
  "x-forwarded-for",
  "x-forwarded-host",
  "x-forwarded-port",
  "x-forwarded-proto",
  "x-real-ip",
  "cf-connecting-ip",
  "cf-ray",
].sort();

const actual = [...PROXY_SIGNALS].sort();

if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  throw new Error(`Unexpected PROXY_SIGNALS: ${actual.join(",")}`);
}

const keyOk = admitKeySetupRequest({
  method: "POST",
  remoteAddress: "127.0.0.1",
  hostHeader: "localhost:4173",
  protocol: "http:",
  origin: "http://localhost:4173",
  contentType: "application/json",
  proxyHeaders: {},
  env: {
    PINOKIO_SHARE_CLOUDFLARE: "false",
    PINOKIO_SHARE_LOCAL: "false",
    PINOKIO_SHARE_VAR: "__gev_sharing_disabled__",
  },
});

if (!keyOk.ok) {
  throw new Error(`Expected Provider Settings loopback request to pass: ${JSON.stringify(keyOk)}`);
}

const keyPublic = admitKeySetupRequest({
  method: "POST",
  remoteAddress: "172.18.0.2",
  hostHeader: "public.example",
  protocol: "http:",
  origin: "http://public.example",
  contentType: "application/json",
  proxyHeaders: {},
  env: {},
});

if (keyPublic.ok) {
  throw new Error("Provider Settings unexpectedly accepts a non-loopback caller");
}

const sameSiteOk = admitSameSiteRequest({
  hostHeader: "public.example",
  protocol: "http:",
  origin: "http://public.example",
  secFetchSite: "same-origin",
  proxyHeaders: {},
});

if (!sameSiteOk.ok) {
  throw new Error(`Expected normal same-origin provider request to pass: ${JSON.stringify(sameSiteOk)}`);
}

const proxied = admitSameSiteRequest({
  hostHeader: "public.example",
  protocol: "http:",
  origin: "http://public.example",
  secFetchSite: "same-origin",
  proxyHeaders: { "x-forwarded-for": "203.0.113.1" },
});

if (proxied.ok) {
  throw new Error("GEV unexpectedly accepts a forwarding-header signal");
}

console.log("GEV security-gate contract: PASS");
'

say "Running GEV's setup doctor"
docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm run doctor

say "Building God's Eye View"
docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm run build

say "Running GEV's upstream unit tests"
docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm test

say "Validating nginx in the exact runtime image"
docker compose run \
  --rm \
  --no-deps \
  --entrypoint nginx \
  gods-eye-view \
  -t \
  -c /etc/nginx/nginx.conf


# ============================================================
# START GEV
# ============================================================

say "Starting God's Eye View"

docker compose up \
  -d \
  --remove-orphans \
  gods-eye-view


# ============================================================
# CONTAINER HEALTH
# ============================================================

say "Waiting for the application and local POWER UP adapter to become healthy"

HEALTH=""

for _ in $(seq 1 60); do
  HEALTH="$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      gods-eye-view \
      2>/dev/null \
      || true
  )"

  if [[ "$HEALTH" == "healthy" ]]; then
    break
  fi

  if [[ "$HEALTH" == "unhealthy" ||
        "$HEALTH" == "exited" ||
        "$HEALTH" == "dead" ]]
  then
    docker compose logs --tail=180 gods-eye-view || true
    die "God's Eye View entered state '$HEALTH'."
  fi

  sleep 5
done

[[ "$HEALTH" == "healthy" ]] ||
  die "God's Eye View did not become healthy in time."


# ============================================================
# NETWORK-SAFETY CHECKS
# ============================================================

[[ -z "$(docker port gods-eye-view 2>/dev/null || true)" ]] ||
  die "Safety check failed: God's Eye View unexpectedly publishes a host port."

TCP_TABLE="$(
  docker exec gods-eye-view \
    sh -lc 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' \
    || true
)"

# 4173 decimal = 0x104D, 127.0.0.1 = 0100007F in /proc/net/tcp.
printf '%s\n' "$TCP_TABLE" \
  | grep -Eq \
    '(^|[[:space:]])0100007F:104D[[:space:]].*[[:space:]]0A([[:space:]]|$)' \
  || die "Safety check failed: GEV is not listening on 127.0.0.1:4173."

if printf '%s\n' "$TCP_TABLE" \
  | grep -Eq \
    '(^|[[:space:]])00000000:104D[[:space:]].*[[:space:]]0A([[:space:]]|$)'
then
  die "Safety check failed: GEV is listening on 0.0.0.0:4173."
fi

unset TCP_TABLE


# ============================================================
# VERIFY TRAEFIK -> GEV PRIVATE CONNECTIVITY
# ============================================================

say "Verifying Traefik-side private connectivity"

if [[ "$TRAEFIK_MODE" == "host" ]]; then
  GEV_CONTAINER_IP="$(
    docker inspect gods-eye-view \
      --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
      | awk 'NF{print; exit}'
  )"

  [[ -n "$GEV_CONTAINER_IP" ]] ||
    die "Could not determine the GEV private Docker IP."

  PRIVATE_ROUTE_CODE="$(
    curl \
      -sS \
      --connect-timeout 5 \
      --max-time 10 \
      -H "Host: ${DOMAIN}" \
      -H "Origin: https://${DOMAIN}" \
      -H "X-GEV-Edge-Token: ${EDGE_TOKEN}" \
      -o /dev/null \
      -w '%{http_code}' \
      "http://${GEV_CONTAINER_IP}:8080/api/setup/status" \
      2>/dev/null \
      || true
  )"

else
  GEV_CONTAINER_IP="$(
    docker inspect gods-eye-view \
      --format '{{range $name, $cfg := .NetworkSettings.Networks}}{{println $name $cfg.IPAddress}}{{end}}' \
      | awk -v wanted="$TRAEFIK_NETWORK" '$1 == wanted {print $2; exit}'
  )"

  [[ -n "$GEV_CONTAINER_IP" ]] ||
    die "Could not determine GEV's IP on the shared Traefik network '$TRAEFIK_NETWORK'."

  PRIVATE_ROUTE_CODE="$(
    docker run \
      --rm \
      --network "$TRAEFIK_NETWORK" \
      -e GEV_TEST_HOST="$DOMAIN" \
      -e GEV_TEST_TOKEN="$EDGE_TOKEN" \
      -e GEV_TEST_IP="$GEV_CONTAINER_IP" \
      "$NODE_IMAGE" \
      node -e '
const http = require("node:http");

const req = http.request(
  {
    hostname: process.env.GEV_TEST_IP,
    port: 8080,
    path: "/api/setup/status",
    method: "GET",
    headers: {
      Host: process.env.GEV_TEST_HOST,
      Origin: `https://${process.env.GEV_TEST_HOST}`,
      "X-GEV-Edge-Token": process.env.GEV_TEST_TOKEN,
    },
  },
  (res) => {
    res.resume();
    res.on("end", () => process.stdout.write(String(res.statusCode)));
  },
);

req.setTimeout(5000, () => req.destroy(new Error("timeout")));
req.on("error", () => process.exit(2));
req.end();
' 2>/dev/null \
      || true
  )"
fi

[[ "$PRIVATE_ROUTE_CODE" == "200" ]] ||
  die "The active Traefik networking layout cannot reach the GEV gateway correctly.

Expected HTTP 200 from the private /api/setup/status path.
Received: ${PRIVATE_ROUTE_CODE:-no response}"


# ============================================================
# LOCAL POWER UP ADAPTER TEST
# ============================================================

say "Testing the POWER UP loopback adapter"

LOCAL_SETUP_POST_CODE="$(
  docker exec gods-eye-view node -e '
const http = require("node:http");
const host = process.env.GEV_PUBLIC_HOST;
const token = process.env.GEV_EDGE_TOKEN;

const req = http.request(
  {
    hostname: "127.0.0.1",
    port: 8080,
    path: "/api/setup/keys",
    method: "POST",
    headers: {
      Host: host,
      Origin: `https://${host}`,
      "Sec-Fetch-Site": "same-origin",
      "Content-Type": "application/json",
      "X-GEV-Edge-Token": token,
    },
  },
  (res) => {
    res.resume();
    res.on("end", () => process.stdout.write(String(res.statusCode)));
  },
);

req.on("error", () => process.exit(2));
req.end("{}");
' 2>/dev/null \
    || true
)"

[[ "$LOCAL_SETUP_POST_CODE" == "400" ]] ||
  die "POWER UP loopback admission failed.

An empty save should pass GEV's local security gate and then return HTTP 400.
Received: ${LOCAL_SETUP_POST_CODE:-no response}"

LOCAL_BAD_ORIGIN_CODE="$(
  docker exec gods-eye-view node -e '
const http = require("node:http");
const host = process.env.GEV_PUBLIC_HOST;
const token = process.env.GEV_EDGE_TOKEN;

const req = http.request(
  {
    hostname: "127.0.0.1",
    port: 8080,
    path: "/api/setup/keys",
    method: "POST",
    headers: {
      Host: host,
      Origin: "https://example.invalid",
      "Sec-Fetch-Site": "cross-site",
      "Content-Type": "application/json",
      "X-GEV-Edge-Token": token,
    },
  },
  (res) => {
    res.resume();
    res.on("end", () => process.stdout.write(String(res.statusCode)));
  },
);

req.on("error", () => process.exit(2));
req.end("{}");
' 2>/dev/null \
    || true
)"

[[ "$LOCAL_BAD_ORIGIN_CODE" == "403" ]] ||
  die "POWER UP cross-origin protection failed.

Expected HTTP 403.
Received: ${LOCAL_BAD_ORIGIN_CODE:-no response}"


# ============================================================
# MANDATORY PUBLIC HTTPS + BASIC AUTH VALIDATION
# ============================================================

say "Waiting for public HTTPS and BasicAuth to become ready"

NOAUTH_CODE=""
AUTH_CODE=""

for _ in $(seq 1 90); do
  NOAUTH_CODE="$(
    curl \
      -sS \
      --connect-timeout 8 \
      --max-time 20 \
      -o /dev/null \
      -w '%{http_code}' \
      "https://${DOMAIN}/" \
      2>/dev/null \
      || true
  )"

  if [[ "$NOAUTH_CODE" == "401" ]]; then
    break
  fi

  sleep 5
done

if [[ "$NOAUTH_CODE" != "401" ]]; then
  printf '\n--- Traefik logs ---\n' >&2
  docker logs --tail=120 "$TRAEFIK_CONTAINER" 2>&1 >&2 || true

  printf '\n--- GEV logs ---\n' >&2
  docker compose logs --tail=120 gods-eye-view >&2 || true

  die "Public HTTPS did not reach the expected BasicAuth challenge.

URL:
https://${DOMAIN}

Last HTTP status:
${NOAUTH_CODE:-no response}

The installer will not report success unless the public authenticated URL is actually usable."
fi

AUTH_CODE="$(
  curl \
    -sS \
    --connect-timeout 8 \
    --max-time 20 \
    -u "${AUTH_USER}:${AUTH_PASS}" \
    -o /dev/null \
    -w '%{http_code}' \
    "https://${DOMAIN}/" \
    2>/dev/null \
    || true
)"

[[ "$AUTH_CODE" =~ ^(200|301|302|304)$ ]] ||
  die "BasicAuth challenged correctly, but the authenticated application request failed.

HTTP status: ${AUTH_CODE:-no response}"


# ============================================================
# REMOTE POWER UP VALIDATION
# ============================================================

say "Testing POWER UP through the real public HTTPS route"

SETUP_STATUS_CODE="$(
  curl \
    -sS \
    --connect-timeout 8 \
    --max-time 20 \
    -u "${AUTH_USER}:${AUTH_PASS}" \
    -H "Origin: https://${DOMAIN}" \
    -o /dev/null \
    -w '%{http_code}' \
    "https://${DOMAIN}/api/setup/status" \
    2>/dev/null \
    || true
)"

SETUP_POST_CODE="$(
  curl \
    -sS \
    --connect-timeout 8 \
    --max-time 20 \
    -u "${AUTH_USER}:${AUTH_PASS}" \
    -H "Origin: https://${DOMAIN}" \
    -H 'Sec-Fetch-Site: same-origin' \
    -H 'Content-Type: application/json' \
    --data '{}' \
    -o /dev/null \
    -w '%{http_code}' \
    "https://${DOMAIN}/api/setup/keys" \
    2>/dev/null \
    || true
)"

SETUP_BAD_ORIGIN_CODE="$(
  curl \
    -sS \
    --connect-timeout 8 \
    --max-time 20 \
    -u "${AUTH_USER}:${AUTH_PASS}" \
    -H 'Origin: https://example.invalid' \
    -H 'Sec-Fetch-Site: cross-site' \
    -H 'Content-Type: application/json' \
    --data '{}' \
    -o /dev/null \
    -w '%{http_code}' \
    "https://${DOMAIN}/api/setup/keys" \
    2>/dev/null \
    || true
)"

[[ "$SETUP_STATUS_CODE" == "200" ]] ||
  die "Remote POWER UP status endpoint failed (HTTP ${SETUP_STATUS_CODE:-none})."

[[ "$SETUP_POST_CODE" == "400" ]] ||
  die "Remote POWER UP save admission failed.

Expected harmless HTTP 400 after passing the local-only gate.
Received: ${SETUP_POST_CODE:-none}"

[[ "$SETUP_BAD_ORIGIN_CODE" == "403" ]] ||
  die "Remote POWER UP cross-origin protection failed.

Expected HTTP 403.
Received: ${SETUP_BAD_ORIGIN_CODE:-none}"


# ============================================================
# NORMAL COST-BEARING GATE VALIDATION
#
# We intentionally do not require a specific application result here;
# no OpenAI key may be configured yet. We only ensure the authenticated,
# same-origin proxy path is NOT being rejected by the proxy-header gate.
# ============================================================

say "Testing the normal provider-route security adapter"

NORMAL_PROVIDER_CODE="$(
  curl \
    -sS \
    --connect-timeout 8 \
    --max-time 20 \
    -u "${AUTH_USER}:${AUTH_PASS}" \
    -H "Origin: https://${DOMAIN}" \
    -H 'Sec-Fetch-Site: same-origin' \
    -H 'Content-Type: application/json' \
    --data '{}' \
    -o /dev/null \
    -w '%{http_code}' \
    "https://${DOMAIN}/api/realtime/token" \
    2>/dev/null \
    || true
)"

[[ -n "$NORMAL_PROVIDER_CODE" &&
   "$NORMAL_PROVIDER_CODE" != "000" &&
   "$NORMAL_PROVIDER_CODE" != "403" ]] ||
  die "The normal provider-route adapter is still being rejected as proxied/cross-site.

HTTP status: ${NORMAL_PROVIDER_CODE:-none}"

NORMAL_BAD_ORIGIN_CODE="$(
  curl \
    -sS \
    --connect-timeout 8 \
    --max-time 20 \
    -u "${AUTH_USER}:${AUTH_PASS}" \
    -H 'Origin: https://example.invalid' \
    -H 'Sec-Fetch-Site: cross-site' \
    -H 'Content-Type: application/json' \
    --data '{}' \
    -o /dev/null \
    -w '%{http_code}' \
    "https://${DOMAIN}/api/realtime/token" \
    2>/dev/null \
    || true
)"

[[ "$NORMAL_BAD_ORIGIN_CODE" == "403" ]] ||
  die "The normal provider-route cross-origin protection did not return HTTP 403.

Received: ${NORMAL_BAD_ORIGIN_CODE:-none}"


# ============================================================
# SMALL OPERATOR HELPERS
# ============================================================

cat > /usr/local/bin/restart-gods-eye-view <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

cd /opt/gods-eye-view
docker compose restart gods-eye-view
EOF

cat > /usr/local/bin/doctor-gods-eye-view <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

cd /opt/gods-eye-view

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm run doctor
EOF

cat > /usr/local/bin/edit-gods-eye-view-keys <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

FILE=/opt/gods-eye-view/app/.env

EDITOR_CMD="${EDITOR:-nano}"

if ! command -v "${EDITOR_CMD%% *}" >/dev/null 2>&1; then
  EDITOR_CMD=vi
fi

$EDITOR_CMD "$FILE"

chown 1000:1000 "$FILE"
chmod 600 "$FILE"

doctor-gods-eye-view
restart-gods-eye-view
EOF

cat > /usr/local/bin/show-gods-eye-view-url <<EOF
#!/usr/bin/env bash
printf '%s\n' 'https://${DOMAIN}'
EOF

chmod 755 \
  /usr/local/bin/restart-gods-eye-view \
  /usr/local/bin/doctor-gods-eye-view \
  /usr/local/bin/edit-gods-eye-view-keys \
  /usr/local/bin/show-gods-eye-view-url

bash -n /usr/local/bin/restart-gods-eye-view
bash -n /usr/local/bin/doctor-gods-eye-view
bash -n /usr/local/bin/edit-gods-eye-view-keys
bash -n /usr/local/bin/show-gods-eye-view-url

cat > "$APP_ROOT/INSTALL_INFO" <<EOF
God's Eye View Hostinger installer
GEV_VERSION=${UPSTREAM_VERSION}
GEV_COMMIT=${UPSTREAM_COMMIT}
NODE_IMAGE=${NODE_IMAGE}
NODE_RUNTIME_VERSION=${NODE_RUNTIME_VERSION}
PUBLIC_URL=https://${DOMAIN}
TRAEFIK_CONTAINER=${TRAEFIK_CONTAINER}
TRAEFIK_MODE=${TRAEFIK_MODE}
EOF

chmod 600 "$APP_ROOT/INSTALL_INFO"


# ============================================================
# FINISH
# ============================================================

unset \
  AUTH_PASS \
  AUTH_CONFIRM \
  AUTH_PAIR \
  AUTH_ESCAPED \
  PASS_BYTES \
  EDGE_TOKEN

printf '\n\033[1;32m====================================================\033[0m\n'
printf '\033[1;32m  God\x27s Eye View installed successfully\033[0m\n'
printf '\033[1;32m====================================================\033[0m\n\n'

printf 'URL:               https://%s\n' "$DOMAIN"
printf 'Hostname mode:     %s\n' "$HOST_MODE"
printf 'Traefik:           %s\n' "$TRAEFIK_CONTAINER"
printf 'Traefik layout:    %s\n' "$TRAEFIK_MODE"
printf 'Username:          %s\n' "$AUTH_USER"

printf 'GEV version:       %s\n' "$UPSTREAM_VERSION"
printf 'GEV commit:        %s\n' "$UPSTREAM_COMMIT"
printf 'Node runtime:      %s\n' "$NODE_RUNTIME_VERSION"

printf 'Authentication:    verified\n'
printf 'HTTPS:             verified with a trusted certificate\n'
printf 'Public host ports: none published by GEV\n'
printf 'Gateway:           Docker-private :8080\n'
printf 'GEV listener:      127.0.0.1:4173 only\n'
printf 'POWER UP:          verified remotely behind BasicAuth\n'
printf 'Cross-origin save: blocked\n'
printf 'Provider route:    proxy-gate adapter verified (HTTP %s)\n' "$NORMAL_PROVIDER_CODE"

printf '\n'
printf 'Next step:\n'
printf '  1. Open https://%s\n' "$DOMAIN"
printf '  2. Log in with the username/password you just created.\n'
printf '  3. Open POWER UP -> Provider Settings and add the provider keys you want.\n'

printf '\n'
printf 'Useful commands:\n'
printf '  show-gods-eye-view-url\n'
printf '  doctor-gods-eye-view\n'
printf '  restart-gods-eye-view\n'
printf '  edit-gods-eye-view-keys   # advanced/hidden .env settings\n'
printf '  cd %s && docker compose logs -f --tail=100 gods-eye-view\n' "$APP_ROOT"

printf '\n'
printf 'Notes:\n'
printf '  • GOOGLE_MAPS_SERVER_API_KEY is hidden by upstream POWER UP; use edit-gods-eye-view-keys if you want a separate server-only Google key.\n'
printf '  • GOOGLE_MAPS_API_KEY, CESIUM_ION_TOKEN and MAPILLARY_CLIENT_TOKEN are browser-exposed by current GEV design; restrict them at the provider to this HTTPS hostname / required scopes.\n'
printf '  • Remote /mcp is intentionally NOT adapted; upstream keeps it direct-local-only.\n'
printf '  • This installer is fresh-install only and is audited for GEV %s.\n\n' "$EXPECTED_GEV_VERSION"
