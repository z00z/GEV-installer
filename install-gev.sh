#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="/opt/gods-eye-view"
SRC_DIR="$APP_ROOT/app"
STATE_DIR="$APP_ROOT/state"
REPO="https://github.com/bilawalsidhu/gods-eye-view.git"
TRAEFIK_NETWORK="traefik-proxy"
CERT_RESOLVER="letsencrypt"
NODE_IMAGE="node:24-bookworm-slim"
RUNTIME_IMAGE="gods-eye-view-hosted:local"
APP_UID=1000
APP_GID=1000

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\n\033[1;31mInstaller stopped (exit %s).\033[0m\n' "$rc" >&2
  if [[ -d "$APP_ROOT" ]] && command -v docker >/dev/null 2>&1; then
    (cd "$APP_ROOT" && docker compose ps 2>/dev/null) || true
    (cd "$APP_ROOT" && docker compose logs --tail=120 2>/dev/null) || true
  fi
  exit "$rc"
}
trap on_error ERR

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this as root."
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Start from Hostinger's Traefik/Docker template."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not available."

if ! docker network inspect "$TRAEFIK_NETWORK" >/dev/null 2>&1; then
  die "The Docker network '$TRAEFIK_NETWORK' does not exist. Deploy/start Hostinger's Traefik template first, then rerun this installer."
fi

if ! docker ps --format '{{.Names}} {{.Image}}' | grep -qi traefik; then
  warn "The '$TRAEFIK_NETWORK' network exists, but I could not confirm a running Traefik container. Installation can continue, but the public URL will not work until Traefik is running."
fi

say "Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git ca-certificates curl apache2-utils nano iproute2 >/dev/null

printf '\nGod\x27s Eye View — authenticated remote deployment\n'
printf '%s\n' '------------------------------------------------'

# Hostinger assigns Docker apps temporary HTTPS hostnames beneath the VPS host,
# e.g. app-ab12.srv123456.hstgr.cloud. Prefer that zero-DNS-setup path.
# A custom hostname can still be supplied non-interactively with GEV_DOMAIN.
HOSTINGER_HOST_FILE="$APP_ROOT/.public-host"
HOSTINGER_BASE_FILE="$APP_ROOT/.hostinger-base-host"
PROJECT_SLUG_FILE="$APP_ROOT/.project-slug"

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

  # Preserve the base selected on the first successful run.
  if [[ -s "$HOSTINGER_BASE_FILE" ]]; then
    candidate="$(normalize_host "$(cat "$HOSTINGER_BASE_FILE" 2>/dev/null || true)")"
    if [[ "$candidate" =~ ^srv[0-9]+\.hstgr\.cloud$ ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  fi

  # If the current shell/project already exposes Hostinger's TRAEFIK_HOST,
  # prefer it before probing the OS hostname.
  candidate="$(normalize_host "${TRAEFIK_HOST:-}")"
  if [[ "$candidate" =~ ^srv[0-9]+\.hstgr\.cloud$ ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  # Hostinger normally sets the VPS hostname itself to srvNNNNNN.hstgr.cloud.
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

  # Catalog projects commonly keep TRAEFIK_HOST in /docker/<project>/.env.
  if [[ -d /docker ]]; then
    while IFS= read -r candidate; do
      candidate="$(normalize_host "$candidate")"
      if [[ "$candidate" =~ ^srv[0-9]+\.hstgr\.cloud$ ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done < <(
      grep -RhsE '^[[:space:]]*TRAEFIK_HOST=' \
        /docker/*/.env /docker/*/*/.env 2>/dev/null \
        | sed -E 's/^[[:space:]]*TRAEFIK_HOST[[:space:]]*=[[:space:]]*//' \
        | tr -d '"\047' \
        || true
    )
  fi

  # Last resort: discover an hstgr.cloud VPS base from running container
  # environments/Traefik Host rules, useful if the OS hostname was customized.
  candidate="$(
    docker inspect $(docker ps -aq 2>/dev/null) 2>/dev/null \
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
  valid_hostname "$DOMAIN" || die "GEV_DOMAIN is not a valid hostname: $DOMAIN"
  HOST_MODE="custom override (GEV_DOMAIN)"

elif [[ -s "$HOSTINGER_HOST_FILE" ]]; then

  DOMAIN="$(normalize_host "$(cat "$HOSTINGER_HOST_FILE")")"
  valid_hostname "$DOMAIN" || die "Saved public hostname is invalid: $DOMAIN"

  if [[ "$DOMAIN" == *.hstgr.cloud ]]; then
    HOST_MODE="saved Hostinger-managed hostname"
  else
    HOST_MODE="saved custom hostname"
  fi

else

  HOSTINGER_BASE="$(detect_hostinger_base || true)"

  [[ -n "$HOSTINGER_BASE" ]] || die \
    "Could not auto-detect this VPS's Hostinger hostname (expected srvNNNNNN.hstgr.cloud).

If you intentionally use a custom domain, rerun as:

GEV_DOMAIN=gev.example.com bash <installer>"

  if [[ -s "$PROJECT_SLUG_FILE" ]]; then

    PROJECT_SLUG="$(cat "$PROJECT_SLUG_FILE" 2>/dev/null || true)"

  else

    PROJECT_SLUG="gods-eye-view-$(
      od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
    )"

  fi

  [[ "$PROJECT_SLUG" =~ ^[a-z0-9][a-z0-9-]{2,62}$ ]] || \
    die "Generated/saved project slug is invalid: $PROJECT_SLUG"

  DOMAIN="${PROJECT_SLUG}.${HOSTINGER_BASE}"

  valid_hostname "$DOMAIN" || \
    die "Generated Hostinger hostname is invalid: $DOMAIN"

  printf '%s\n' "$HOSTINGER_BASE" > "$HOSTINGER_BASE_FILE"
  printf '%s\n' "$PROJECT_SLUG" > "$PROJECT_SLUG_FILE"
  printf '%s\n' "$DOMAIN" > "$HOSTINGER_HOST_FILE"

  chmod 600 \
    "$HOSTINGER_BASE_FILE" \
    "$PROJECT_SLUG_FILE" \
    "$HOSTINGER_HOST_FILE"

  HOST_MODE="Hostinger-managed temporary hostname"

fi

# Keep the selected hostname stable across reruns, including a GEV_DOMAIN
# override, so the same BasicAuth/Origin policy continues to match.
printf '%s\n' "$DOMAIN" > "$HOSTINGER_HOST_FILE"
chmod 600 "$HOSTINGER_HOST_FILE"

say "Using public hostname: $DOMAIN ($HOST_MODE)"

# Unique Traefik object names avoid collisions with another GEV deployment.
ROUTER_SUFFIX="$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-10)"
ROUTER_ID="gev-${ROUTER_SUFFIX}"

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

  PASS_BYTES="$(printf '%s' "$AUTH_PASS" | wc -c | tr -d ' ')"

  if (( PASS_BYTES < 12 )); then
    printf 'Please use at least 12 bytes.\n' >/dev/tty
    continue
  fi

  if (( PASS_BYTES > 64 )); then
    printf 'Please use no more than 64 bytes (avoids bcrypt truncation).\n' >/dev/tty
    continue
  fi

  break

done

# Read the password from stdin so plaintext never appears in htpasswd argv.
AUTH_PAIR="$(
  printf '%s\n' "$AUTH_PASS" |
    htpasswd -niB -C 10 "$AUTH_USER"
)"

# Docker Compose treats $$ as a literal $ in label values.
AUTH_ESCAPED="$(
  printf '%s' "$AUTH_PAIR" |
    sed 's/\$/\$\$/g'
)"

say "Preparing the official God's Eye View source"

mkdir -p \
  "$APP_ROOT" \
  "$STATE_DIR/cache" \
  "$STATE_DIR/logs"

chmod 700 \
  "$APP_ROOT" \
  "$STATE_DIR" \
  "$STATE_DIR/cache" \
  "$STATE_DIR/logs"

if [[ -d "$SRC_DIR/.git" ]]; then

  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" remote set-url origin "$REPO"

  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" fetch --depth=1 origin main

  # Preflight TARGET revision before touching the running checkout.
  PREFLIGHT_DIR="$(mktemp -d)"

  trap 'rm -rf "${PREFLIGHT_DIR:-}"' EXIT

  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" \
    show origin/main:src/localRequestGate.mjs \
    > "$PREFLIGHT_DIR/localRequestGate.mjs" || \
      die "Upstream target is missing src/localRequestGate.mjs. Existing instance was left untouched."

  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" \
    show origin/main:src/keySetupCore.mjs \
    > "$PREFLIGHT_DIR/keySetupCore.mjs" || \
      die "Upstream target is missing src/keySetupCore.mjs. Existing instance was left untouched."

  EXPECTED_PROXY_SIGNALS="cf-connecting-ip cf-ray forwarded via x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-proto x-real-ip"

  TARGET_PROXY_SIGNALS="$(
    sed -n \
      '/PROXY_SIGNALS = Object.freeze(\[/,/\]);/p' \
      "$PREFLIGHT_DIR/localRequestGate.mjs" \
      | grep -oE "'[^']+'" \
      | tr -d "'" \
      | sort \
      | xargs \
      || true
  )"

  [[ "$TARGET_PROXY_SIGNALS" == "$EXPECTED_PROXY_SIGNALS" ]] || \
    die "Upstream target proxy-signal policy changed. Existing instance was left untouched; review this installer before updating."

  grep -Fq "LOOPBACK_ADDRESSES" \
    "$PREFLIGHT_DIR/keySetupCore.mjs" || \
      die "Upstream target Provider Settings loopback policy changed. Existing instance was left untouched."

  grep -Fq \
    "Provider Settings answers only local hostnames" \
    "$PREFLIGHT_DIR/keySetupCore.mjs" || \
      die "Upstream target Provider Settings Host policy changed. Existing instance was left untouched."

  grep -Fq \
    "Provider Settings requires an exact local Origin" \
    "$PREFLIGHT_DIR/keySetupCore.mjs" || \
      die "Upstream target Provider Settings Origin policy changed. Existing instance was left untouched."

  rm -rf "$PREFLIGHT_DIR"
  trap - EXIT

  unset \
    PREFLIGHT_DIR \
    TARGET_PROXY_SIGNALS \
    EXPECTED_PROXY_SIGNALS

  if [[ -f "$APP_ROOT/docker-compose.yml" ]]; then

    say "Stopping the existing God's Eye View runtime before updating source"

    (
      cd "$APP_ROOT"
      docker compose stop gods-eye-view >/dev/null 2>&1
    ) || warn "Could not cleanly stop the previous GEV runtime; continuing with source refresh."

  fi

  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" reset --hard HEAD >/dev/null

  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" checkout -q -B main origin/main

  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" reset --hard origin/main >/dev/null

else

  rm -rf "$SRC_DIR"

  git clone \
    --depth=1 \
    --branch main \
    "$REPO" \
    "$SRC_DIR"

fi

[[ -f "$SRC_DIR/package.json" ]] || \
  die "Upstream checkout is missing package.json."

[[ -f "$SRC_DIR/package-lock.json" ]] || \
  die "Upstream checkout is missing package-lock.json."

[[ -f "$SRC_DIR/.env.example" ]] || \
  die "Upstream checkout is missing .env.example."

[[ -f "$SRC_DIR/src/keySetupCore.mjs" ]] || \
  die "Upstream checkout is missing Provider Settings core."

[[ -f "$SRC_DIR/src/localRequestGate.mjs" ]] || \
  die "Upstream checkout is missing local request gate."

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

[[ "$ACTUAL_PROXY_SIGNALS" == "$EXPECTED_PROXY_SIGNALS" ]] || \
  die "Upstream proxy-signal policy changed. Expected: $EXPECTED_PROXY_SIGNALS ; found: ${ACTUAL_PROXY_SIGNALS:-none}. Review the installer before deploying this newer GEV revision."

unset ACTUAL_PROXY_SIGNALS EXPECTED_PROXY_SIGNALS

grep -Fq \
  "LOOPBACK_ADDRESSES" \
  "$SRC_DIR/src/keySetupCore.mjs" || \
    die "Upstream Provider Settings loopback policy changed. Review required."

grep -Fq \
  "Provider Settings answers only local hostnames" \
  "$SRC_DIR/src/keySetupCore.mjs" || \
    die "Upstream Provider Settings Host policy changed. Review required."

grep -Fq \
  "Provider Settings requires an exact local Origin" \
  "$SRC_DIR/src/keySetupCore.mjs" || \
    die "Upstream Provider Settings Origin policy changed. Review required."

# Provider Settings atomically writes .env in the repo root, therefore the
# unprivileged application user must own the source directory.
chown -R \
  "$APP_UID:$APP_GID" \
  "$SRC_DIR" \
  "$STATE_DIR"

chmod 700 \
  "$SRC_DIR" \
  "$STATE_DIR" \
  "$STATE_DIR/cache" \
  "$STATE_DIR/logs"

FRESH_ENV=0

if [[ ! -f "$SRC_DIR/.env" ]]; then

  cp "$SRC_DIR/.env.example" "$SRC_DIR/.env"
  FRESH_ENV=1

else

  while IFS= read -r line || [[ -n "$line" ]]; do

    if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$ ]]; then

      key="${BASH_REMATCH[1]}"

      if ! grep -Eq \
        "^[[:space:]]*#?[[:space:]]*${key}=" \
        "$SRC_DIR/.env"
      then
        printf \
          '\n# Added from newer upstream .env.example\n%s\n' \
          "$line" \
          >> "$SRC_DIR/.env"
      fi

    fi

  done < "$SRC_DIR/.env.example"

fi

# OpenSky's upstream template defaults to oauth.
# For this hosted install auto is preferable:
# OAuth is used if configured, otherwise anonymous mode works.
CURRENT_OPENSKY_MODE="$(
  grep -E \
    '^[[:space:]]*OPENSKY_AUTH_MODE=' \
    "$SRC_DIR/.env" 2>/dev/null \
    | tail -n1 \
    | sed -E 's/^[^=]*=//' \
    | tr -d '"' \
    | tr -d "'" \
    | xargs \
    || true
)"

OPENSKY_ID="$(
  grep -E \
    '^[[:space:]]*OPENSKY_CLIENT_ID=' \
    "$SRC_DIR/.env" 2>/dev/null \
    | tail -n1 \
    | sed -E 's/^[^=]*=//' \
    | tr -d '"' \
    | tr -d "'" \
    | xargs \
    || true
)"

OPENSKY_SECRET="$(
  grep -E \
    '^[[:space:]]*OPENSKY_CLIENT_SECRET=' \
    "$SRC_DIR/.env" 2>/dev/null \
    | tail -n1 \
    | sed -E 's/^[^=]*=//' \
    | tr -d '"' \
    | tr -d "'" \
    | xargs \
    || true
)"

if (( FRESH_ENV == 1 )) || {
  [[ "$CURRENT_OPENSKY_MODE" == "oauth" ]] &&
  [[ -z "$OPENSKY_ID" && -z "$OPENSKY_SECRET" ]]
}; then

  if grep -Eq \
    '^[[:space:]]*OPENSKY_AUTH_MODE=' \
    "$SRC_DIR/.env"
  then

    sed -i -E \
      's/^[[:space:]]*OPENSKY_AUTH_MODE=.*/OPENSKY_AUTH_MODE=auto/' \
      "$SRC_DIR/.env"

  else

    printf '\nOPENSKY_AUTH_MODE=auto\n' >> "$SRC_DIR/.env"

  fi

fi

unset \
  CURRENT_OPENSKY_MODE \
  OPENSKY_ID \
  OPENSKY_SECRET

chmod 600 "$SRC_DIR/.env"
chown "$APP_UID:$APP_GID" "$SRC_DIR/.env"

UPSTREAM_COMMIT="$(
  git -c safe.directory="$SRC_DIR" \
    -C "$SRC_DIR" \
    rev-parse --short=12 HEAD
)"

UPSTREAM_VERSION="$(
  grep -m1 '"version"' "$SRC_DIR/package.json" \
    | sed -E \
      's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
    || true
)"

# Per-install internal token proving the request traversed our Traefik route.
EDGE_TOKEN="$(
  od -An -N32 -tx1 /dev/urandom |
    tr -d ' \n'
)"

[[ "$EDGE_TOKEN" =~ ^[0-9a-f]{64}$ ]] || \
  die "Could not generate the internal edge token."

cat > "$APP_ROOT/nginx.conf" <<'EOF'
pid /tmp/gev-nginx/nginx.pid;
error_log /dev/stderr warn;

events {}

http {
  access_log off;

  # Hostinger's generated hostname can be long enough to exceed nginx's
  # small default hash buckets. Explicit sizing avoids startup failures.
  map_hash_bucket_size 128;
  server_names_hash_bucket_size 128;

  client_body_temp_path /tmp/gev-nginx/client_body;
  proxy_temp_path /tmp/gev-nginx/proxy;
  fastcgi_temp_path /tmp/gev-nginx/fastcgi;
  uwsgi_temp_path /tmp/gev-nginx/uwsgi;
  scgi_temp_path /tmp/gev-nginx/scgi;

  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }

  # Normal public application requests arrive over HTTPS at Traefik,
  # but Vite itself receives HTTP locally. Translate only OUR exact public
  # Origin so GEV's same-origin checks still work.
  map $http_origin $gev_app_origin {
    default $http_origin;
    "https://__DOMAIN__" "http://__DOMAIN__";
  }

  map $http_origin $gev_setup_origin_state {
    default              bad;
    ""                   none;
    "https://__DOMAIN__" same;
  }

  server {
    listen 8080;
    server_name __DOMAIN__;

    client_max_body_size 32m;

    # Only our Traefik middleware inserts the private token.
    # Another container directly contacting nginx is rejected.
    if ($http_x_gev_edge_token != "__EDGE_TOKEN__") {
      return 403;
    }

    if ($host != "__DOMAIN__") {
      return 444;
    }

    # POWER UP status endpoint:
    # Transform the authenticated external request into the loopback-local
    # request shape expected by upstream GEV.
    location = /api/setup/status {

      if ($request_method != GET) {
        return 405;
      }

      if ($gev_setup_origin_state = bad) {
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
      proxy_set_header X-Forwarded-Server "";
      proxy_set_header X-Forwarded-Scheme "";
      proxy_set_header X-Forwarded-Protocol "";
      proxy_set_header X-Forwarded-Ssl "";
      proxy_set_header X-Real-IP "";
      proxy_set_header True-Client-IP "";

      proxy_set_header CF-Connecting-IP "";
      proxy_set_header CF-Connecting-IPv6 "";
      proxy_set_header CF-Ray "";
      proxy_set_header CF-Visitor "";
      proxy_set_header CDN-Loop "";

      proxy_buffering off;
      proxy_request_buffering off;

      proxy_read_timeout 60s;
      proxy_send_timeout 60s;
    }

    # POWER UP credential-save endpoint.
    location = /api/setup/keys {

      if ($request_method != POST) {
        return 405;
      }

      # Saving credentials must originate from the exact public GEV page.
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
      proxy_set_header X-Forwarded-Server "";
      proxy_set_header X-Forwarded-Scheme "";
      proxy_set_header X-Forwarded-Protocol "";
      proxy_set_header X-Forwarded-Ssl "";
      proxy_set_header X-Real-IP "";
      proxy_set_header True-Client-IP "";

      proxy_set_header CF-Connecting-IP "";
      proxy_set_header CF-Connecting-IPv6 "";
      proxy_set_header CF-Ray "";
      proxy_set_header CF-Visitor "";
      proxy_set_header CDN-Loop "";

      proxy_buffering off;
      proxy_request_buffering off;

      proxy_read_timeout 60s;
      proxy_send_timeout 60s;
    }

    # Everything else goes to the normal GEV application.
    location / {

      proxy_pass http://127.0.0.1:4173;
      proxy_http_version 1.1;

      proxy_set_header Host $host;
      proxy_set_header Origin $gev_app_origin;

      # Needed for Vite HMR / WebSockets.
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;

      # Do not leak HTTP BasicAuth credentials to GEV.
      proxy_set_header Authorization "";
      proxy_set_header Proxy-Authorization "";
      proxy_set_header X-GEV-Edge-Token "";

      # GEV deliberately refuses requests carrying reverse-proxy signals.
      # Strip the complete current upstream deny-list plus neighboring
      # common proxy/CDN headers.
      proxy_set_header Forwarded "";
      proxy_set_header Via "";

      proxy_set_header X-Forwarded-For "";
      proxy_set_header X-Forwarded-Host "";
      proxy_set_header X-Forwarded-Port "";
      proxy_set_header X-Forwarded-Proto "";
      proxy_set_header X-Forwarded-Server "";
      proxy_set_header X-Forwarded-Scheme "";
      proxy_set_header X-Forwarded-Protocol "";
      proxy_set_header X-Forwarded-Ssl "";

      proxy_set_header X-Real-IP "";
      proxy_set_header True-Client-IP "";

      proxy_set_header CF-Connecting-IP "";
      proxy_set_header CF-Connecting-IPv6 "";
      proxy_set_header CF-Ray "";
      proxy_set_header CF-Visitor "";

      proxy_set_header CDN-Loop "";

      # Origin and Sec-Fetch-* are intentionally NOT blindly removed:
      # they remain part of GEV's own cross-site protections.
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

# Vite is deliberately bound only to loopback.
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

  kill -TERM \
    "$NGINX_PID" \
    "$GEV_PID" \
    2>/dev/null || true

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
    res.on('end', () => {
      process.exit(res.statusCode === 200 ? 0 : 1);
    });
  },
);

req.setTimeout(4000, () => {
  req.destroy(new Error('health timeout'));
});

req.on('error', () => process.exit(1));

req.end();
EOF

cat > "$APP_ROOT/.dockerignore" <<'EOF'
*
!Dockerfile
!nginx.conf
!runtime-entrypoint.sh
!healthcheck.mjs
EOF

chmod 600 "$APP_ROOT/.dockerignore"

cat > "$APP_ROOT/Dockerfile" <<EOF
FROM ${NODE_IMAGE}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash nginx ca-certificates \
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

      # Native GEV/Pinokio sharing stays disabled.
      # Remote access happens exclusively through Traefik.
      PINOKIO_SHARE_CLOUDFLARE: "false"
      PINOKIO_SHARE_LOCAL: "false"
      PINOKIO_SHARE_VAR: "__gev_sharing_disabled__"

      PUPPETEER_SKIP_DOWNLOAD: "true"

    volumes:

      - ./app:/app

      - gev-node-modules:/app/node_modules

      - ./state/cache:/app/.gev-cache
      - ./state/logs:/app/.gev-logs

    networks:

      - traefik-proxy

    labels:

      - 'traefik.enable=true'

      - 'traefik.docker.network=${TRAEFIK_NETWORK}'

      - 'traefik.http.services.${ROUTER_ID}.loadbalancer.server.port=8080'

      # HTTP -> HTTPS
      - 'traefik.http.routers.${ROUTER_ID}-http.rule=Host(\`${DOMAIN}\`)'
      - 'traefik.http.routers.${ROUTER_ID}-http.entrypoints=web'
      - 'traefik.http.routers.${ROUTER_ID}-http.service=${ROUTER_ID}'
      - 'traefik.http.routers.${ROUTER_ID}-http.middlewares=${ROUTER_ID}-https-redirect@docker'

      - 'traefik.http.middlewares.${ROUTER_ID}-https-redirect.redirectscheme.scheme=https'
      - 'traefik.http.middlewares.${ROUTER_ID}-https-redirect.redirectscheme.permanent=true'

      # HTTPS router
      - 'traefik.http.routers.${ROUTER_ID}.rule=Host(\`${DOMAIN}\`)'
      - 'traefik.http.routers.${ROUTER_ID}.entrypoints=websecure'

      - 'traefik.http.routers.${ROUTER_ID}.service=${ROUTER_ID}'

      - 'traefik.http.routers.${ROUTER_ID}.tls=true'
      - 'traefik.http.routers.${ROUTER_ID}.tls.certresolver=${CERT_RESOLVER}'

      # Authentication happens before the edge token is injected.
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


networks:

  traefik-proxy:
    external: true


volumes:

  gev-node-modules:
EOF

chmod 600 "$APP_ROOT/docker-compose.yml"
chmod 600 "$APP_ROOT/nginx.conf"
chmod 755 "$APP_ROOT/runtime-entrypoint.sh"

chmod 644 \
  "$APP_ROOT/healthcheck.mjs" \
  "$APP_ROOT/Dockerfile"

chown "$APP_UID:$APP_GID" \
  "$APP_ROOT/nginx.conf"

say "Validating Docker Compose configuration"

cd "$APP_ROOT"

docker compose config -q

say "Building the local GEV runtime image"

docker compose build \
  --pull \
  gods-eye-view

say "Pulling the Node maintenance image"

docker compose pull \
  gev-maintenance

say "Preparing the persistent node_modules volume"

docker compose run \
  --rm \
  --no-deps \
  --user 0:0 \
  gev-maintenance \
  sh -lc \
  'mkdir -p /app/node_modules /app/.gev-cache /app/.gev-logs && chown -R 1000:1000 /app/node_modules /app/.gev-cache /app/.gev-logs'

say "Installing the exact locked npm dependencies"

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm ci --no-audit --no-fund

say "Running the upstream setup doctor"

# Missing optional provider credentials do not make the doctor fail.
docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm run doctor

say "Building God's Eye View with the current configuration"

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm run build

say "Running the upstream unit test suite"

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm test

say "Validating the gateway configuration in the exact runtime image"

docker compose run \
  --rm \
  --no-deps \
  --entrypoint nginx \
  gods-eye-view \
  -t \
  -c /etc/nginx/nginx.conf

say "Starting the authenticated stack"

docker compose up \
  -d \
  --force-recreate \
  --remove-orphans \
  gods-eye-view

say "Waiting for God's Eye View + gateway + Provider Settings to become healthy"

HEALTH=""

for _ in $(seq 1 60); do

  HEALTH="$(
    docker inspect \
      --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
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

    docker compose logs \
      --tail=180 \
      gods-eye-view \
      || true

    die "God's Eye View entered state '$HEALTH'."

  fi

  sleep 5

done

[[ "$HEALTH" == "healthy" ]] || \
  die "God's Eye View did not become healthy in time.

Check:

cd $APP_ROOT
docker compose logs --tail=200 gods-eye-view"

# Nothing from this project may publish a host port.
if [[ -n "$(docker port gods-eye-view 2>/dev/null || true)" ]]; then
  die "Safety check failed: God's Eye View unexpectedly has a published host port."
fi

docker inspect \
  gods-eye-view \
  --format '{{json .NetworkSettings.Networks}}' \
  | grep -Fq "\"${TRAEFIK_NETWORK}\"" || \
    die "Safety check failed: runtime is not attached to '$TRAEFIK_NETWORK'."

# 4173 must be IPv4 loopback-only.
# 127.0.0.1 = 0100007F
# 4173       = 104D
TCP_TABLE="$(
  docker exec gods-eye-view \
    sh -lc \
    'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' \
    || true
)"

printf '%s\n' "$TCP_TABLE" \
  | grep -Eq \
    '(^|[[:space:]])0100007F:104D[[:space:]].*[[:space:]]0A([[:space:]]|$)' \
  || die "Safety check failed: GEV is not listening on 127.0.0.1:4173 as intended."

if printf '%s\n' "$TCP_TABLE" \
  | grep -Eq \
    '(^|[[:space:]])00000000:104D[[:space:]].*[[:space:]]0A([[:space:]]|$)'
then
  die "Safety check failed: GEV is listening on 0.0.0.0:4173."
fi

unset TCP_TABLE

say "Checking the POWER UP local-only adapter"

# Empty JSON is deliberately invalid.
# HTTP 400 proves the request passed GEV's local-only security gate
# without changing any credentials.
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
      "X-GEV-Edge-Token": token
    }
  },
  res => {
    res.resume();
    res.on("end", () => process.stdout.write(String(res.statusCode)));
  }
);

req.on("error", () => process.exit(2));
req.end("{}");
' 2>/dev/null || true
)"

[[ "$LOCAL_SETUP_POST_CODE" == "400" ]] || \
  die "POWER UP local adapter self-test failed (expected harmless HTTP 400, got ${LOCAL_SETUP_POST_CODE:-none})."

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
      "X-GEV-Edge-Token": token
    }
  },
  res => {
    res.resume();
    res.on("end", () => process.stdout.write(String(res.statusCode)));
  }
);

req.on("error", () => process.exit(2));
req.end("{}");
' 2>/dev/null || true
)"

[[ "$LOCAL_BAD_ORIGIN_CODE" == "403" ]] || \
  die "POWER UP cross-origin local self-test failed (expected HTTP 403, got ${LOCAL_BAD_ORIGIN_CODE:-none})."

RESOLVED_IP="$(
  getent ahostsv4 "$DOMAIN" 2>/dev/null \
    | awk 'NR==1{print $1}' \
    || true
)"

VPS_IP="$(
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk \
      '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' \
    || true
)"

if [[ -z "$RESOLVED_IP" ]]; then

  if [[ "$DOMAIN" == *.hstgr.cloud ]]; then

    warn "$DOMAIN has not appeared in DNS yet.

Hostinger-managed temporary hostnames normally resolve automatically;
Traefik/HTTPS will become available once Hostinger DNS sees the hostname."

  else

    warn "$DOMAIN does not currently resolve in DNS.

Point it to this VPS before expecting HTTPS to work."

  fi

elif [[ -n "$VPS_IP" && "$RESOLVED_IP" != "$VPS_IP" ]]; then

  warn "$DOMAIN currently resolves to $RESOLVED_IP while this VPS reports $VPS_IP.

This can be intentional, for example when a proxy/CDN is in front."

fi

say "Checking HTTPS and authentication"

NOAUTH_CODE=""
AUTH_CODE=""
TLS_OK=0

# Do not use curl -k.
# Public verification only passes with a valid certificate.
if [[ -n "$RESOLVED_IP" ]]; then

  for _ in $(seq 1 18); do

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
      TLS_OK=1
      break
    fi

    sleep 5

  done

fi

if (( TLS_OK == 1 )); then

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

fi

AUTH_STATUS="pending DNS/valid HTTPS certificate"

if [[ "$NOAUTH_CODE" == "401" &&
      "$AUTH_CODE" =~ ^(200|301|302|304)$ ]]
then

  AUTH_STATUS="verified with valid HTTPS (anonymous=401, authenticated=${AUTH_CODE})"

elif [[ "$NOAUTH_CODE" == "401" ]]; then

  AUTH_STATUS="valid HTTPS + anonymous access blocked; authenticated request returned ${AUTH_CODE}"

elif [[ -n "$RESOLVED_IP" ]]; then

  warn "The container is healthy, but a TLS-verified request to:

https://${DOMAIN}/

did not reach the expected BasicAuth 401 yet.

Check:
  • DNS
  • ports 80/443
  • Traefik logs
  • Let's Encrypt issuance

If Cloudflare proxying is enabled, temporarily disabling the proxy can simplify first certificate issuance."

fi

SETUP_STATUS_CODE=""
SETUP_POST_CODE=""
SETUP_BAD_ORIGIN_CODE=""

if [[ "$AUTH_CODE" =~ ^(200|301|302|304)$ ]]; then

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

  [[ "$SETUP_STATUS_CODE" == "200" ]] || \
    die "POWER UP Provider Settings status self-test failed (HTTP ${SETUP_STATUS_CODE:-none})."

  [[ "$SETUP_POST_CODE" == "400" ]] || \
    die "POWER UP Provider Settings save admission self-test failed (expected harmless HTTP 400, got ${SETUP_POST_CODE:-none})."

  [[ "$SETUP_BAD_ORIGIN_CODE" == "403" ]] || \
    die "Provider Settings cross-origin protection self-test failed (expected 403, got ${SETUP_BAD_ORIGIN_CODE:-none})."

fi

cat > /usr/local/bin/restart-gods-eye-view <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

cd /opt/gods-eye-view

docker compose up \
  -d \
  --force-recreate \
  gods-eye-view
EOF

chmod 755 /usr/local/bin/restart-gods-eye-view

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

chmod 755 /usr/local/bin/doctor-gods-eye-view

cat > /usr/local/bin/update-gods-eye-view <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT=/opt/gods-eye-view
SRC_DIR=$APP_ROOT/app

APP_UID=1000
APP_GID=1000

cd "$SRC_DIR"

GIT=(
  git
  -c
  safe.directory="$SRC_DIR"
  -C
  "$SRC_DIR"
)

"${GIT[@]}" fetch \
  --depth=1 \
  origin main

# Preflight target before taking the existing instance offline.
PREFLIGHT_DIR="$(mktemp -d)"

cleanup_preflight() {
  rm -rf "$PREFLIGHT_DIR"
}

trap cleanup_preflight EXIT

"${GIT[@]}" show \
  origin/main:src/localRequestGate.mjs \
  > "$PREFLIGHT_DIR/localRequestGate.mjs" || {
    printf \
      'Update refused: target revision is missing src/localRequestGate.mjs; current instance remains online.\n' \
      >&2
    exit 1
  }

"${GIT[@]}" show \
  origin/main:src/keySetupCore.mjs \
  > "$PREFLIGHT_DIR/keySetupCore.mjs" || {
    printf \
      'Update refused: target revision is missing src/keySetupCore.mjs; current instance remains online.\n' \
      >&2
    exit 1
  }

EXPECTED_PROXY_SIGNALS="cf-connecting-ip cf-ray forwarded via x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-proto x-real-ip"

TARGET_PROXY_SIGNALS="$(
  sed -n \
    '/PROXY_SIGNALS = Object.freeze(\[/,/\]);/p' \
    "$PREFLIGHT_DIR/localRequestGate.mjs" \
    | grep -oE "'[^']+'" \
    | tr -d "'" \
    | sort \
    | xargs \
    || true
)"

if [[ "$TARGET_PROXY_SIGNALS" != "$EXPECTED_PROXY_SIGNALS" ]]; then

  printf \
    'Update refused: upstream proxy-signal policy changed; current instance remains online. Review/re-run the audited installer first.\n' \
    >&2

  exit 1

fi

grep -Fq \
  'LOOPBACK_ADDRESSES' \
  "$PREFLIGHT_DIR/keySetupCore.mjs" || {
    printf \
      'Update refused: Provider Settings loopback policy changed; current instance remains online.\n' \
      >&2
    exit 1
  }

grep -Fq \
  'Provider Settings answers only local hostnames' \
  "$PREFLIGHT_DIR/keySetupCore.mjs" || {
    printf \
      'Update refused: Provider Settings Host policy changed; current instance remains online.\n' \
      >&2
    exit 1
  }

grep -Fq \
  'Provider Settings requires an exact local Origin' \
  "$PREFLIGHT_DIR/keySetupCore.mjs" || {
    printf \
      'Update refused: Provider Settings Origin policy changed; current instance remains online.\n' \
      >&2
    exit 1
  }

rm -rf "$PREFLIGHT_DIR"
trap - EXIT

unset \
  PREFLIGHT_DIR \
  TARGET_PROXY_SIGNALS \
  EXPECTED_PROXY_SIGNALS

# Target is compatible. Stop runtime before replacing live source/dependencies.
cd "$APP_ROOT"

docker compose stop gods-eye-view

cd "$SRC_DIR"

"${GIT[@]}" reset \
  --hard HEAD \
  >/dev/null

"${GIT[@]}" checkout \
  -q \
  -B main \
  origin/main

"${GIT[@]}" reset \
  --hard origin/main \
  >/dev/null

[[ -f "$SRC_DIR/src/keySetupCore.mjs" &&
   -f "$SRC_DIR/src/localRequestGate.mjs" ]] || {
  printf \
    'Update stopped: checked-out security-gate files disappeared unexpectedly.\n' \
    >&2
  exit 1
}

# Preserve existing values while adding newly introduced template variables.
while IFS= read -r line || [[ -n "$line" ]]; do

  if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$ ]]; then

    key="${BASH_REMATCH[1]}"

    if ! grep -Eq \
      "^[[:space:]]*#?[[:space:]]*${key}=" \
      "$SRC_DIR/.env"
    then

      printf \
        '\n# Added from newer upstream .env.example\n%s\n' \
        "$line" \
        >> "$SRC_DIR/.env"

    fi

  fi

done < "$SRC_DIR/.env.example"

chown -R \
  "$APP_UID:$APP_GID" \
  "$SRC_DIR"

chmod 600 "$SRC_DIR/.env"

cd "$APP_ROOT"

docker compose config -q

docker compose build \
  --pull \
  gods-eye-view

docker compose pull \
  gev-maintenance

docker compose run \
  --rm \
  --no-deps \
  --user 0:0 \
  gev-maintenance \
  sh -lc \
  'mkdir -p /app/node_modules /app/.gev-cache /app/.gev-logs && chown -R 1000:1000 /app/node_modules /app/.gev-cache /app/.gev-logs'

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm ci --no-audit --no-fund

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm run doctor

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm run build

docker compose run \
  --rm \
  --no-deps \
  gev-maintenance \
  npm test

docker compose run \
  --rm \
  --no-deps \
  --entrypoint nginx \
  gods-eye-view \
  -t \
  -c /etc/nginx/nginx.conf

docker compose up \
  -d \
  --force-recreate \
  gods-eye-view

HEALTH=""

for _ in $(seq 1 60); do

  HEALTH="$(
    docker inspect \
      --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
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

    docker compose logs \
      --tail=180 \
      gods-eye-view \
      || true

    printf \
      "Update failed: God's Eye View entered state %s.\n" \
      "$HEALTH" \
      >&2

    exit 1

  fi

  sleep 5

done

[[ "$HEALTH" == "healthy" ]] || {
  printf \
    'Update did not reach healthy state in time.\n' \
    >&2
  exit 1
}

POST_CODE="$(
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
      "X-GEV-Edge-Token": token
    }
  },
  res => {
    res.resume();
    res.on("end", () => process.stdout.write(String(res.statusCode)));
  }
);

req.on("error", () => process.exit(2));
req.end("{}");
' 2>/dev/null || true
)"

[[ "$POST_CODE" == "400" ]] || {
  printf \
    'Update failed: POWER UP adapter admission check returned %s (expected 400).\n' \
    "${POST_CODE:-none}" \
    >&2
  exit 1
}

BAD_ORIGIN_CODE="$(
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
      "X-GEV-Edge-Token": token
    }
  },
  res => {
    res.resume();
    res.on("end", () => process.stdout.write(String(res.statusCode)));
  }
);

req.on("error", () => process.exit(2));
req.end("{}");
' 2>/dev/null || true
)"

[[ "$BAD_ORIGIN_CODE" == "403" ]] || {
  printf \
    'Update failed: POWER UP cross-origin check returned %s (expected 403).\n' \
    "${BAD_ORIGIN_CODE:-none}" \
    >&2
  exit 1
}

printf \
  'Updated to %s\n' \
  "$(
    git -c safe.directory="$SRC_DIR" \
      -C "$SRC_DIR" \
      rev-parse --short=12 HEAD
  )"
EOF

chmod 755 /usr/local/bin/update-gods-eye-view

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

printf '\nValidating provider configuration...\n'

doctor-gods-eye-view

printf '\nRestarting God\x27s Eye View so dotenv changes are reloaded...\n'

restart-gods-eye-view
EOF

chmod 755 /usr/local/bin/edit-gods-eye-view-keys

# Validate all generated helper scripts before declaring success.
bash -n /usr/local/bin/restart-gods-eye-view
bash -n /usr/local/bin/doctor-gods-eye-view
bash -n /usr/local/bin/update-gods-eye-view
bash -n /usr/local/bin/edit-gods-eye-view-keys

unset \
  AUTH_PASS \
  AUTH_CONFIRM \
  AUTH_PAIR \
  AUTH_ESCAPED \
  PASS_BYTES \
  EDGE_TOKEN

printf '\n\033[1;32m===============================================\033[0m\n'
printf '\033[1;32m  God\x27s Eye View is deployed and protected\033[0m\n'
printf '\033[1;32m===============================================\033[0m\n\n'

printf 'URL:              https://%s\n' "$DOMAIN"
printf 'Hostname mode:    %s\n' "$HOST_MODE"
printf 'Username:         %s\n' "$AUTH_USER"
printf 'Authentication:   %s\n' "$AUTH_STATUS"

printf 'GEV version:      %s\n' \
  "${UPSTREAM_VERSION:-unknown}"

printf 'Upstream commit:  %s\n' \
  "$UPSTREAM_COMMIT"

printf 'Public exposure:  Traefik only; no host ports are published by GEV\n'

printf 'GEV listener:     127.0.0.1:4173 inside the runtime container only\n'

printf 'Provider Settings: remote POWER UP enabled behind BasicAuth + strict Origin validation\n'

if [[ -n "$SETUP_STATUS_CODE" ]]; then

  printf \
    'POWER UP test:    status=%s, harmless-save=%s, bad-origin=%s\n' \
    "$SETUP_STATUS_CODE" \
    "$SETUP_POST_CODE" \
    "$SETUP_BAD_ORIGIN_CODE"

fi

printf '\n'

printf 'Provider keys:    configure them in POWER UP -> Provider Settings after login\n'

printf 'Advanced Google: GOOGLE_MAPS_SERVER_API_KEY is hidden by upstream; GOOGLE_MAPS_API_KEY falls back for those server calls, or use edit-gods-eye-view-keys for a separate server-only key\n'

printf 'API/config file: %s/.env\n' \
  "$SRC_DIR"

printf 'Edit advanced:   edit-gods-eye-view-keys\n'
printf 'Provider doctor: doctor-gods-eye-view\n'
printf 'Restart:         restart-gods-eye-view\n'
printf 'Update upstream: update-gods-eye-view\n'

printf \
  'Logs:            cd %s && docker compose logs -f --tail=100 gods-eye-view\n\n' \
  "$APP_ROOT"

printf 'Important:\n'

printf \
  '  • GOOGLE_MAPS_API_KEY, CESIUM_ION_TOKEN and MAPILLARY_CLIENT_TOKEN are browser-exposed by GEV design; restrict them to your HTTPS domain/provider scopes.\n'

printf \
  '  • For a separate GOOGLE_MAPS_SERVER_API_KEY, restrict it to the VPS egress IP address(es) and only the required Google APIs.\n'

printf \
  '  • Remote /mcp remains untouched/disabled by this adapter.\n'

printf \
  '  • Operator-specific settings such as LOCAL_RECEIVER_FEEDS and OVERPASS_UPSTREAMS still require infrastructure/URLs you supply separately.\n\n'
