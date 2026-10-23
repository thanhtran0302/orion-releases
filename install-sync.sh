#!/usr/bin/env bash
# Orion Sync en une commande, sur le serveur où Hermes est installé :
#   - Postgres et le service dans Docker Compose (/opt/orion) ;
#   - le HTTPS : nginx s'il sert déjà Hermes (on y ajoute /orion/), sinon Caddy avec un certificat automatique ;
#   - l'API de Hermes activée si besoin, et le terminal du Mac (outil mac_terminal) déclaré à Hermes ;
#   - les notifications iPhone par le relais (une clé de relais, à créer sur le serveur qui a la clé APNs) ;
#   - une sauvegarde de la base chaque nuit.
# Relancer le script met à jour, sans toucher aux secrets ni redémarrer Hermes.
#
#   curl -fsSL https://raw.githubusercontent.com/thanhtran0302/orion-releases/main/install-sync.sh | sudo bash
#
# Options :
#   --domain NOM         le nom du serveur, pour Caddy (sans : <ip>.sslip.io)
#   --relay-key CLÉ      la clé du relais des notifications (sans : demandée, ou pas de notifications)
#   --relay-url URL      le relais (https://hermes.tarslink.app)
#   --proxy MODE         auto (défaut), nginx, caddy, ou none (tu publies toi-même 127.0.0.1:8650 sous /orion/)
#   --hermes-home DIR    le dossier de Hermes, s'il n'est pas ~/.hermes d'un utilisateur
#   --archive FICHIER    une archive d'Orion Sync déjà téléchargée
#   --yes                sans questions
set -euo pipefail

VERSION="0.8.0"
SHA256="26e529196a4c8d7b2d7a9ec79d4d20f09856c3bbc22c4078482e738b3df36437"
RELEASES="https://github.com/thanhtran0302/orion-releases/releases/download/sync-v$VERSION"
DIR=/opt/orion
SYNC_PORT=8650

DOMAIN=""
RELAY_KEY="${ORION_RELAY_KEY:-}"
RELAY_URL=""
DEFAULT_RELAY="https://hermes.tarslink.app"
PROXY=auto
HERMES_HOME_OPT=""
ARCHIVE=""
YES=0

# ---------------------------------------------------------------- Aides

bold=$(printf '\033[1m'); dim=$(printf '\033[2m'); red=$(printf '\033[31m'); green=$(printf '\033[32m'); off=$(printf '\033[0m')
[ -t 1 ] || { bold=""; dim=""; red=""; green=""; off=""; }
step() { printf '\n%s▸ %s%s\n' "$bold" "$*" "$off"; }
ok() { printf '  %s✓%s %s\n' "$green" "$off" "$*"; }
note() { printf '  %s%s%s\n' "$dim" "$*" "$off"; }
warn() { printf '  %s!%s %s\n' "$red" "$off" "$*" >&2; }
die() { printf '\n%sImpossible d'"'"'aller plus loin :%s %s\n' "$red" "$off" "$*" >&2; exit 1; }

# Une question, au terminal même quand le script arrive par « curl | bash ». Sans terminal ou avec --yes : la valeur par défaut.
ask() {
  local prompt=$1 default=${2:-} secret=${3:-} answer=""
  if [ "$YES" = 1 ] || ! { : < /dev/tty; } 2>/dev/null; then printf '%s' "$default"; return; fi
  if [ -n "$secret" ]; then
    read -r -s -p "  $prompt " answer < /dev/tty || true
    printf '\n' > /dev/tty
  else
    read -r -p "  $prompt " answer < /dev/tty || true
  fi
  printf '%s' "${answer:-$default}"
}

random_hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Fichiers « CLÉ=valeur » : lire une valeur (sans guillemets), en écrire une en gardant le reste du fichier.
kv_get() {
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' || true
}
kv_set() {
  local file=$1 key=$2 value=$3 tmp
  tmp=$(mktemp "$file.XXXXXX")
  { [ -f "$file" ] && grep -vE "^$key=" "$file" || true; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  if [ -f "$file" ]; then chown --reference="$file" "$tmp"; chmod --reference="$file" "$tmp"; else chmod 600 "$tmp"; fi
  mv "$tmp" "$file"
}

port_used() { ss -ltnH "( sport = :$1 )" 2>/dev/null | grep -q .; }

# ---------------------------------------------------------------- Options

while [ $# -gt 0 ]; do
  case $1 in
    --domain) DOMAIN=${2:?}; shift 2 ;;
    --relay-key) RELAY_KEY=${2:?}; shift 2 ;;
    --relay-url) RELAY_URL=${2:?}; shift 2 ;;
    --proxy) PROXY=${2:?}; shift 2 ;;
    --hermes-home) HERMES_HOME_OPT=${2:?}; shift 2 ;;
    --archive) ARCHIVE=${2:?}; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "option inconnue : $1 (--help)" ;;
  esac
done
case $PROXY in auto|nginx|caddy|none) ;; *) die "--proxy : auto, nginx, caddy ou none" ;; esac

printf '%sOrion Sync %s%s\n' "$bold" "$VERSION" "$off"

[ "$(id -u)" = 0 ] || die "lance-le avec sudo."
[ -d /run/systemd/system ] || die "il faut un Linux avec systemd (Ubuntu, Debian…)."
for tool in curl tar sha256sum ss runuser; do command -v "$tool" > /dev/null || die "il manque la commande $tool."; done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- Hermes

step "Hermes"
HH=""
sudo_home=""
[ -n "${SUDO_USER:-}" ] && sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
for candidate in "$HERMES_HOME_OPT" "${sudo_home:+$sudo_home/.hermes}" /root/.hermes /home/*/.hermes; do
  if [ -n "$candidate" ] && [ -f "$candidate/config.yaml" ]; then HH=$candidate; break; fi
done
[ -n "$HH" ] || die "Hermes introuvable (pas de config.yaml dans ~/.hermes). Installe Hermes d'abord, ou donne son dossier avec --hermes-home."
HUSER=$(stat -c %U "$HH")
HUID=$(id -u "$HUSER")
HUHOME=$(getent passwd "$HUSER" | cut -d: -f6)
HENV="$HH/.env"
ok "dans $HH (utilisateur $HUSER)"

# La commande hermes, comme l'utilisateur de Hermes, avec de quoi parler à son systemd.
as_hermes() {
  runuser -u "$HUSER" -- env HOME="$HUHOME" HERMES_HOME="$HH" XDG_RUNTIME_DIR="/run/user/$HUID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$HUID/bus" PATH="$HUHOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}
HBIN=""
if as_hermes sh -c 'command -v hermes' > /dev/null 2>&1; then HBIN=hermes; fi
[ -n "$HBIN" ] || warn "la commande hermes est introuvable pour $HUSER : le terminal du Mac sera à déclarer à la main."

if [ ! -f "$HENV" ]; then install -m 600 -o "$HUSER" -g "$(id -gn "$HUSER")" /dev/null "$HENV"; fi
HERMES_ENV_CHANGED=0
KEY_GENERATED=0
if [ "$(kv_get "$HENV" API_SERVER_ENABLED)" != "true" ]; then
  kv_set "$HENV" API_SERVER_ENABLED true
  HERMES_ENV_CHANGED=1
  ok "API de Hermes activée"
fi
if [ -z "$(kv_get "$HENV" API_SERVER_KEY)" ]; then
  kv_set "$HENV" API_SERVER_KEY "$(random_hex)"
  HERMES_ENV_CHANGED=1
  KEY_GENERATED=1
  ok "clé de l'API créée"
fi
MCP_TOKEN=$(kv_get "$HENV" ORION_MCP_TOKEN)
if [ -z "$MCP_TOKEN" ]; then
  MCP_TOKEN=$(random_hex)
  kv_set "$HENV" ORION_MCP_TOKEN "$MCP_TOKEN"
  HERMES_ENV_CHANGED=1
fi
HERMES_PORT=$(kv_get "$HENV" API_SERVER_PORT)
HERMES_PORT=${HERMES_PORT:-8642}

# ---------------------------------------------------------------- Docker

step "Docker"
if ! command -v docker > /dev/null || ! docker compose version > /dev/null 2>&1; then
  note "installation de Docker (get.docker.com)…"
  curl -fsSL https://get.docker.com | sh > "$tmp/docker.log" 2>&1 || { tail -n 20 "$tmp/docker.log" >&2; die "Docker ne s'est pas installé."; }
fi
systemctl enable --now docker > /dev/null 2>&1 || true
ok "$(docker compose version | head -n 1)"

# ---------------------------------------------------------------- Le service

step "Orion Sync $VERSION"
if [ -n "$ARCHIVE" ]; then
  cp "$ARCHIVE" "$tmp/orion-sync.tar.gz"
else
  curl -fsSL "$RELEASES/orion-sync-$VERSION.tar.gz" -o "$tmp/orion-sync.tar.gz" || die "téléchargement impossible : $RELEASES/orion-sync-$VERSION.tar.gz"
fi
echo "$SHA256  $tmp/orion-sync.tar.gz" | sha256sum -c --quiet - > /dev/null 2>&1 || die "l'archive ne correspond pas à son empreinte (téléchargement abîmé ?)."
install -d -m 755 "$DIR"
rm -rf "$DIR/app.new"
mkdir "$DIR/app.new"
tar -xzf "$tmp/orion-sync.tar.gz" -C "$DIR/app.new" --strip-components=1 --no-same-owner
rm -rf "$DIR/app"
mv "$DIR/app.new" "$DIR/app"
cp "$DIR/app/bundle/compose.yaml" "$DIR/compose.yaml"
ok "dans $DIR"

# Les secrets restent d'une installation à l'autre.
ENVF="$DIR/.env"
SYNCF="$DIR/sync.env"
[ -f "$ENVF" ] || install -m 600 /dev/null "$ENVF"
[ -f "$SYNCF" ] || install -m 600 /dev/null "$SYNCF"
PG_PASSWORD=$(kv_get "$ENVF" POSTGRES_PASSWORD)
[ -n "$PG_PASSWORD" ] || { PG_PASSWORD=$(random_hex); kv_set "$ENVF" POSTGRES_PASSWORD "$PG_PASSWORD"; }
PG_PORT=$(kv_get "$ENVF" PG_PORT)
if [ -z "$PG_PORT" ]; then
  PG_PORT=5438
  while port_used "$PG_PORT"; do PG_PORT=$((PG_PORT + 1)); done
  kv_set "$ENVF" PG_PORT "$PG_PORT"
fi
kv_set "$ENVF" ORION_SYNC_VERSION "$VERSION"
kv_set "$ENVF" HERMES_PORT "$HERMES_PORT"

# ---------------------------------------------------------------- Notifications

step "Notifications iPhone"
[ -n "$RELAY_KEY" ] || RELAY_KEY=$(kv_get "$SYNCF" PUSH_RELAY_KEY)
[ -n "$RELAY_URL" ] || RELAY_URL=$(kv_get "$SYNCF" PUSH_RELAY_URL)
RELAY_URL=${RELAY_URL:-$DEFAULT_RELAY}
RELAY_URL=${RELAY_URL%/}
[ -n "$RELAY_KEY" ] || RELAY_KEY=$(ask "Clé du relais des notifications (vide : sans notifications) :" "" secret)
if [ -n "$RELAY_KEY" ]; then
  [[ $RELAY_KEY =~ ^orr_[A-Za-z0-9_-]{20,100}$ ]] || die "la clé du relais ressemble à orr_… (créée par scripts/relay-key.ts)."
  if curl -fsS --max-time 10 "$RELAY_URL/orion/v1/health" 2>/dev/null | grep -q '"relay"'; then
    ok "par le relais $RELAY_URL"
  else
    warn "le relais $RELAY_URL ne répond pas comme un relais : les notifications attendront qu'il réponde."
  fi
else
  note "sans clé de relais : pas de notifications (relance le script avec --relay-key pour les ajouter)."
fi

cat > "$SYNCF.new" <<EOF
DATABASE_URL=postgres://orion:$PG_PASSWORD@127.0.0.1:$PG_PORT/orion
HERMES_URL=http://127.0.0.1:$HERMES_PORT
HOST=127.0.0.1
PORT=$SYNC_PORT
ORION_MCP_TOKEN=$MCP_TOKEN
EOF
[ -z "$RELAY_KEY" ] || printf 'PUSH_RELAY_URL=%s\nPUSH_RELAY_KEY=%s\n' "$RELAY_URL" "$RELAY_KEY" >> "$SYNCF.new"
chmod 600 "$SYNCF.new"
mv "$SYNCF.new" "$SYNCF"

# ---------------------------------------------------------------- HTTPS

step "HTTPS"
NGINX_CONF=""
TO_HERMES="proxy_pass[[:space:]]+https?://(127\.0\.0\.1|localhost|\[::1\]):$HERMES_PORT\b"
if [ "$PROXY" = auto ] || [ "$PROXY" = nginx ]; then
  if command -v nginx > /dev/null && systemctl is-active --quiet nginx; then
    NGINX_CONF=$(grep -RlE "$TO_HERMES" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -n 1 || true)
    [ -z "$NGINX_CONF" ] || NGINX_CONF=$(readlink -f "$NGINX_CONF")
  fi
  [ "$PROXY" = nginx ] && [ -z "$NGINX_CONF" ] && die "nginx ne sert pas Hermes (aucun proxy_pass vers le port $HERMES_PORT)."
fi

PUBLIC=""
PROFILES=""
if [ -n "$NGINX_CONF" ]; then
  install -D -m 644 "$DIR/app/bundle/nginx-orion-sync.conf" /etc/nginx/snippets/orion-sync.conf
  if grep -qE "location[[:space:]]+/orion/|snippets/orion-sync\.conf" "$NGINX_CONF"; then
    ok "nginx sert déjà /orion/ ($NGINX_CONF)"
  else
    backup="/var/backups/orion-install/$(basename "$NGINX_CONF").$(date +%F-%H%M%S)"
    install -d -m 700 /var/backups/orion-install
    cp -p "$NGINX_CONF" "$backup"
    # Avant le bloc location qui mène à Hermes.
    line=$(grep -nE "$TO_HERMES" "$NGINX_CONF" | head -n 1 | cut -d: -f1)
    at=$(head -n "$line" "$NGINX_CONF" | grep -nE "^[[:space:]]*location[[:space:]]" | tail -n 1 | cut -d: -f1)
    [ -n "$at" ] || die "bloc location de Hermes introuvable dans $NGINX_CONF."
    sed -i "${at}i\\    include /etc/nginx/snippets/orion-sync.conf;" "$NGINX_CONF"
    if nginx -t > /dev/null 2>&1; then
      systemctl reload nginx
      ok "nginx : /orion/ ajouté à $NGINX_CONF (avant : $backup)"
    else
      cp -p "$backup" "$NGINX_CONF"
      die "nginx refuse la configuration avec /orion/ : rien n'a changé. Ajoute à la main /etc/nginx/snippets/orion-sync.conf dans le bloc server de Hermes."
    fi
  fi
  # Le nom du bloc server de Hermes : le dernier server_name avant son proxy_pass.
  line=$(grep -nE "$TO_HERMES" "$NGINX_CONF" | head -n 1 | cut -d: -f1)
  name=$(head -n "$line" "$NGINX_CONF" | grep -E "^[[:space:]]*server_name[[:space:]]" | tail -n 1 | awk '{print $2}' | tr -d ';' || true)
  [ -z "$name" ] || [ "$name" = "_" ] || PUBLIC="https://$name"
elif [ "$PROXY" = none ]; then
  note "à toi de publier, en HTTPS, Hermes (127.0.0.1:$HERMES_PORT) à la racine et Orion Sync (127.0.0.1:$SYNC_PORT) sous /orion/ :"
  note "le bloc nginx est dans $DIR/app/bundle/nginx-orion-sync.conf"
else
  ours=0
  docker ps --format '{{.Names}}' | grep -qx orion-caddy && ours=1
  if [ "$ours" = 0 ] && { port_used 80 || port_used 443; }; then
    die "les ports 80 et 443 sont pris, mais pas par un nginx qui sert Hermes. Publie Orion toi-même (--proxy none)."
  fi
  [ -n "$DOMAIN" ] || DOMAIN=$(kv_get "$ENVF" ORION_DOMAIN)
  if [ -z "$DOMAIN" ]; then
    ip=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    fallback=""
    [ -z "$ip" ] || fallback="$(printf '%s' "$ip" | tr . -).sslip.io"
    DOMAIN=$(ask "Nom du serveur pour le certificat (vide : ${fallback:-aucun}) :" "$fallback")
  fi
  [ -n "$DOMAIN" ] || die "il faut un nom (--domain) pour le certificat."
  resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
  [ -n "$resolved" ] || warn "$DOMAIN ne pointe vers aucune adresse : le certificat attendra que le nom existe."
  cp "$DIR/app/bundle/Caddyfile" "$DIR/Caddyfile"
  kv_set "$ENVF" ORION_DOMAIN "$DOMAIN"
  PROFILES=caddy
  if command -v ufw > /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp > /dev/null && ufw allow 443/tcp > /dev/null && note "pare-feu : 80 et 443 ouverts"
  fi
  PUBLIC="https://$DOMAIN"
  ok "Caddy, certificat automatique pour $DOMAIN"
fi
kv_set "$ENVF" COMPOSE_PROFILES "$PROFILES"
# Passé de Caddy à nginx : Caddy n'a plus à tenir les ports.
[ "$PROFILES" = caddy ] || docker rm -f orion-caddy > /dev/null 2>&1 || true

# ---------------------------------------------------------------- Démarrage

step "Démarrage"
note "construction et démarrage des conteneurs (une minute la première fois)…"
if docker ps --format '{{.Names}}' | grep -qx orion-sync; then
  note "si des tours de groupe sont en cours, l'ancien service les laisse finir (jusqu'à 10 min)."
fi
COMPOSE_PROFILES=$PROFILES docker compose -f "$DIR/compose.yaml" up -d --build --quiet-pull > "$tmp/compose.log" 2>&1 || { cat "$tmp/compose.log" >&2; die "Docker Compose n'a pas démarré les conteneurs."; }
for _ in $(seq 1 90); do
  curl -fsS "http://127.0.0.1:$SYNC_PORT/orion/v1/health" > "$tmp/health" 2>/dev/null && break
  sleep 1
done
[ -s "$tmp/health" ] || { docker logs --tail 30 orion-sync >&2 || true; die "Orion Sync ne répond pas sur 127.0.0.1:$SYNC_PORT."; }
ok "Orion Sync répond ($(grep -o '"features":\[[^]]*\]' "$tmp/health"))"

# ---------------------------------------------------------------- Le terminal du Mac, pour Hermes

step "Le terminal du Mac"
MCP_OK=0
if [ -n "$HBIN" ]; then
  as_hermes hermes config set mcp_servers.orion-mac.url "http://127.0.0.1:$SYNC_PORT/mcp/mac" > /dev/null
  # La clé reste dans le .env de Hermes : la configuration n'en garde que le nom.
  as_hermes hermes config set mcp_servers.orion-mac.headers.Authorization 'Bearer ${ORION_MCP_TOKEN}' > /dev/null
  as_hermes hermes config set mcp_servers.orion-mac.timeout 480 > /dev/null
  as_hermes hermes config set mcp_servers.orion-mac.enabled true > /dev/null
  ok "Hermes connaît l'outil mac_terminal (serveur MCP orion-mac)"
  if as_hermes hermes mcp test orion-mac 2>&1 | grep -q mac_terminal; then MCP_OK=1; else warn "hermes mcp test orion-mac ne trouve pas l'outil."; fi
else
  note "à ajouter dans $HH/config.yaml, sous mcp_servers: orion-mac (url http://127.0.0.1:$SYNC_PORT/mcp/mac,"
  note "headers Authorization: Bearer \${ORION_MCP_TOKEN}, timeout 480) ; ORION_MCP_TOKEN est dans $HENV."
fi

if [ "$HERMES_ENV_CHANGED" = 1 ]; then
  if [ -n "$HBIN" ] && as_hermes hermes gateway restart > "$tmp/gateway.log" 2>&1; then
    ok "Hermes redémarré (nouveaux réglages)"
  else
    warn "redémarre Hermes toi-même pour qu'il prenne ses nouveaux réglages (hermes gateway restart)."
  fi
fi
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$HERMES_PORT/v1/health" > /dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$HERMES_PORT/v1/health" > /dev/null 2>&1 && ok "l'API de Hermes répond" || warn "l'API de Hermes ne répond pas sur 127.0.0.1:$HERMES_PORT."

# ---------------------------------------------------------------- Sauvegardes

step "Sauvegarde de chaque nuit"
install -m 755 "$DIR/app/deploy/orion-backup.sh" /usr/local/sbin/orion-backup
install -m 644 "$DIR/app/deploy/orion-backup.service" "$DIR/app/deploy/orion-backup.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now orion-backup.timer > /dev/null 2>&1
ok "vers /var/backups/orion-sync (14 jours)"

# ---------------------------------------------------------------- Vérification de dehors

if [ -n "$PUBLIC" ]; then
  step "Vérification par $PUBLIC"
  reached=0
  for _ in $(seq 1 45); do
    if curl -fsS --max-time 5 "$PUBLIC/orion/v1/health" > /dev/null 2>&1; then reached=1; break; fi
    sleep 2
  done
  if [ "$reached" = 1 ]; then ok "joignable en HTTPS"; else warn "pas encore joignable en HTTPS (certificat, DNS ou pare-feu du fournisseur ?)."; fi
fi

# ---------------------------------------------------------------- C'est prêt

printf '\n%sOrion est prêt.%s\n' "$bold" "$off"
unknown="(l'adresse HTTPS de ce serveur)"
printf '  Adresse : %s\n' "${PUBLIC:-$unknown}"
if [ "$KEY_GENERATED" = 1 ]; then
  printf '  Clé     : %s\n' "$(kv_get "$HENV" API_SERVER_KEY)"
else
  printf '  Clé     : celle de Hermes (sudo grep ^API_SERVER_KEY= %s)\n' "$HENV"
fi
printf '  Dans Orion, sur Mac ou iPhone : l'"'"'adresse et la clé, Tester, puis Enregistrer.\n'
[ -n "$RELAY_KEY" ] && printf '  Notifications : par le relais.\n' || printf '  Notifications : aucune (pas de clé de relais).\n'
[ "$MCP_OK" = 1 ] && printf '  Terminal du Mac : prêt (Réglages, « Ce Mac » dans l'"'"'app Mac).\n'
printf '  Mettre à jour : relance la même commande.\n'
