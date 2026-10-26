#!/usr/bin/env bash
# Orion Sync en une commande, sur le serveur où Hermes est installé :
#   - le serveur relié au compte du client chez orionspace.ai, avec son code d'installation ori_… (créé par
#     « pnpm run server add <e-mail> » dans apps/account) : le client se connecte ensuite dans Orion avec son e-mail ;
#   - Postgres et le service dans Docker Compose (/opt/orion) ;
#   - le HTTPS : nginx s'il sert déjà Hermes, sinon Caddy avec un certificat automatique. Tout passe par Orion Sync,
#     qui relaie vers Hermes avec la clé de Hermes : elle ne quitte plus le serveur ;
#   - l'API de Hermes activée si besoin, et le terminal du Mac (outil mac_terminal) déclaré à Hermes ;
#   - les notifications iPhone par le relais (une clé de relais, à créer sur le serveur qui a la clé APNs) ;
#   - une sauvegarde de la base chaque nuit.
# Un code refusé ne change rien au serveur. Relancer le script met à jour, sans toucher aux secrets ni au compte, et
# sans redémarrer Hermes.
#
#   curl -fsSL https://raw.githubusercontent.com/thanhtran0302/orion-releases/main/install-sync.sh | sudo bash
#
# Options :
#   --account-code CODE  le code d'installation ori_… (sans : demandé ; inutile pour une mise à jour)
#   --account-url URL    orionspace.ai (https://compte.orionspace.app)
#   --domain NOM         le nom du serveur, pour Caddy (sans : <ip>.sslip.io)
#   --relay-key CLÉ      la clé du relais des notifications (sans : demandée, ou pas de notifications)
#   --relay-url URL      le relais (https://hermes.tarslink.app)
#   --proxy MODE         auto (défaut), nginx, caddy, ou none (tu publies toi-même 127.0.0.1:8650, tout le site)
#   --hermes-home DIR    le dossier de Hermes, s'il n'est pas ~/.hermes d'un utilisateur
#   --archive FICHIER    une archive d'Orion Sync déjà téléchargée
#   --yes                sans questions
set -euo pipefail

VERSION="0.13.0"
SHA256="b1b7c44cc56f077db72fa446b63daf853bc8f124fcfb0180c4ed0c1b0ba36877"
RELEASES="https://github.com/thanhtran0302/orion-releases/releases/download/sync-v$VERSION"
DIR=/opt/orion
ENVF="$DIR/.env"
SYNCF="$DIR/sync.env"
SYNC_PORT=8650

ACCOUNT_CODE="${ORION_ACCOUNT_CODE:-}"
ACCOUNT_URL="${ORION_ACCOUNT_URL:-}"
DEFAULT_ACCOUNT="https://compte.orionspace.app"
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

# Un champ texte d'une réponse JSON d'une ligne (sans guillemet dans la valeur).
json_get() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -n 1 | cut -d'"' -f4 || true; }

port_used() { ss -ltnH "( sport = :$1 )" 2>/dev/null | grep -q .; }

# ---------------------------------------------------------------- Options

while [ $# -gt 0 ]; do
  case $1 in
    --account-code) ACCOUNT_CODE=${2:?}; shift 2 ;;
    --account-url) ACCOUNT_URL=${2:?}; shift 2 ;;
    --domain) DOMAIN=${2:?}; shift 2 ;;
    --relay-key) RELAY_KEY=${2:?}; shift 2 ;;
    --relay-url) RELAY_URL=${2:?}; shift 2 ;;
    --proxy) PROXY=${2:?}; shift 2 ;;
    --hermes-home) HERMES_HOME_OPT=${2:?}; shift 2 ;;
    --archive) ARCHIVE=${2:?}; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail/{/^#/p;}' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Jusqu'à l'enregistrement du serveur, le script ne fait que regarder et demander : un code refusé ne change rien.

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
HERMES_PORT=$(kv_get "$HENV" API_SERVER_PORT)
HERMES_PORT=${HERMES_PORT:-8642}

# ---------------------------------------------------------------- Le compte du client

step "Compte du client"
ACCOUNT_URL=${ACCOUNT_URL:-$(kv_get "$ENVF" ORION_ACCOUNT_URL)}
ACCOUNT_URL=${ACCOUNT_URL:-$DEFAULT_ACCOUNT}
ACCOUNT_URL=${ACCOUNT_URL%/}
[[ $ACCOUNT_URL =~ ^https?://[^[:space:]/]+$ ]] || die "--account-url : une adresse comme $DEFAULT_ACCOUNT."
[[ $ACCOUNT_URL == https://* ]] || warn "$ACCOUNT_URL n'est pas en HTTPS : seulement pour un essai."
SERVER_ID=$(kv_get "$SYNCF" ACCOUNT_SERVER_ID)
OWNER=$(kv_get "$SYNCF" ACCOUNT_OWNER)
ISSUER=$(kv_get "$SYNCF" ACCOUNT_ISSUER)
# Une mise à jour garde le compte : un code ne sert que pour relier le serveur, ou changer son adresse.
if [ -z "$ACCOUNT_CODE" ] && [ -z "$SERVER_ID" ]; then
  note "le code d'installation se crée avec « pnpm run server add <e-mail du client> », dans apps/account."
  ACCOUNT_CODE=$(ask "Code d'installation du compte du client (ori_…) :" "" secret)
fi
if [ -n "$ACCOUNT_CODE" ]; then
  [[ $ACCOUNT_CODE =~ ^ori_[A-Za-z0-9_-]{43}$ ]] || die "le code d'installation ressemble à ori_… (43 caractères après ori_, donné par pnpm run server add)."
  ok "code d'installation reçu ; le serveur sera relié au compte par $ACCOUNT_URL"
elif [ -n "$SERVER_ID" ] && [ -n "$OWNER" ] && [ -n "$ISSUER" ]; then
  ok "déjà relié au compte $OWNER ($SERVER_ID)"
else
  die "il faut le code d'installation du compte du client (--account-code ori_…). Le client s'inscrit d'abord dans Orion, puis « pnpm run server add <son e-mail> », dans apps/account, donne le code."
fi

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

# ---------------------------------------------------------------- HTTPS : par où passer

step "HTTPS"
SNIPPET=/etc/nginx/snippets/orion-sync.conf
NGINX_CONF=""
# Le bloc server de nginx qui sert Hermes : il y mène encore (première installation), ou il mène déjà au service.
TO_HERMES="proxy_pass[[:space:]]+https?://(127\.0\.0\.1|localhost|\[::1\]):$HERMES_PORT\b"
SERVED="$TO_HERMES|snippets/orion-sync\.conf"
if [ "$PROXY" = auto ] || [ "$PROXY" = nginx ]; then
  if command -v nginx > /dev/null && systemctl is-active --quiet nginx; then
    NGINX_CONF=$(grep -RlE "$SERVED" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -n 1 || true)
    [ -z "$NGINX_CONF" ] || NGINX_CONF=$(readlink -f "$NGINX_CONF")
  fi
  [ "$PROXY" = nginx ] && [ -z "$NGINX_CONF" ] && die "nginx ne sert pas Hermes (aucun proxy_pass vers le port $HERMES_PORT)."
fi

PUBLIC=""
PROFILES=""
if [ -n "$NGINX_CONF" ]; then
  # Le nom du bloc server de Hermes : le dernier server_name avant son proxy_pass (ou l'inclusion du service).
  line=$(grep -nE "$SERVED" "$NGINX_CONF" | head -n 1 | cut -d: -f1)
  name=$(head -n "$line" "$NGINX_CONF" | grep -E "^[[:space:]]*server_name[[:space:]]" | tail -n 1 | awk '{print $2}' | tr -d ';' || true)
  if [ -n "$DOMAIN" ]; then PUBLIC="https://$DOMAIN"; elif [ -n "$name" ] && [ "$name" != "_" ]; then PUBLIC="https://$name"; fi
  ok "par nginx ($NGINX_CONF)"
elif [ "$PROXY" = none ]; then
  [ -z "$DOMAIN" ] || PUBLIC="https://$DOMAIN"
  note "à toi de publier, en HTTPS, tout le site vers Orion Sync (127.0.0.1:$SYNC_PORT), sauf /mcp/ :"
  note "le modèle est $DIR/app/bundle/Caddyfile (ou nginx-orion-sync.conf, à côté)."
else
  ours=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx orion-caddy && ours=1
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
  PROFILES=caddy
  PUBLIC="https://$DOMAIN"
  ok "par Caddy, avec un certificat automatique pour $DOMAIN"
fi
[ -z "$PUBLIC" ] || ok "adresse : $PUBLIC"

# ---------------------------------------------------------------- Relier le serveur au compte

if [ -n "$ACCOUNT_CODE" ]; then
  step "Relier le serveur au compte"
  [ -n "$PUBLIC" ] || die "il faut l'adresse publique du serveur pour le relier au compte : relance avec --domain <nom>."
  # POST /api/servers/register (docs/comptes.md). Le code passe par l'entrée de curl, pas par sa ligne de commande.
  status=$(printf '{"code":"%s","url":"%s"}' "$ACCOUNT_CODE" "$PUBLIC" |
    curl -sS --max-time 20 -o "$tmp/register.json" -w '%{http_code}' -H 'Content-Type: application/json' \
      --data-binary @- "$ACCOUNT_URL/api/servers/register" 2> "$tmp/register.err") || status=000
  answer=$(cat "$tmp/register.json" 2>/dev/null || true)
  case $status in
    200) ;;
    401) die "orionspace.ai refuse ce code d'installation : inconnu, expiré (il vaut 7 jours) ou déjà servi. Rien n'a changé sur ce serveur. Crée-en un autre (pnpm run server add <e-mail du client>) et relance avec --account-code." ;;
    000) die "orionspace.ai ne répond pas ($ACCOUNT_URL : $(tr -d '\n' < "$tmp/register.err")). Rien n'a changé sur ce serveur : relance plus tard." ;;
    *) die "orionspace.ai a répondu $status ($(json_get "$answer" message)). Rien n'a changé sur ce serveur." ;;
  esac
  SERVER_ID=$(json_get "$answer" serverId)
  OWNER=$(json_get "$answer" owner)
  ISSUER=$(json_get "$answer" issuer)
  ISSUER=${ISSUER%/}
  if ! [[ $SERVER_ID =~ ^srv_[A-Za-z0-9_-]+$ && $OWNER =~ ^user_[A-Za-z0-9_-]+$ && $ISSUER =~ ^https?://[^[:space:]]+$ ]]; then
    die "réponse inattendue d'orionspace.ai : $answer. Le code a peut-être servi : crée-en un autre avant de relancer."
  fi
  # Gardé tout de suite : le code ne resservira pas, une installation interrompue reprend avec ce compte.
  install -d -m 755 "$DIR"
  [ -f "$ENVF" ] || install -m 600 /dev/null "$ENVF"
  [ -f "$SYNCF" ] || install -m 600 /dev/null "$SYNCF"
  kv_set "$SYNCF" ACCOUNT_ISSUER "$ISSUER"
  kv_set "$SYNCF" ACCOUNT_SERVER_ID "$SERVER_ID"
  kv_set "$SYNCF" ACCOUNT_OWNER "$OWNER"
  kv_set "$ENVF" ORION_ACCOUNT_URL "$ACCOUNT_URL"
  kv_set "$ENVF" ORION_REGISTERED_URL "$PUBLIC"
  ok "relié au compte $OWNER ($SERVER_ID), à l'adresse $PUBLIC"
else
  registered=$(kv_get "$ENVF" ORION_REGISTERED_URL)
  if [ -n "$PUBLIC" ] && [ -n "$registered" ] && [ "$registered" != "$PUBLIC" ]; then
    warn "orionspace.ai connaît ce serveur à $registered : pour lui donner $PUBLIC, crée un code (pnpm run server add) et relance avec --account-code."
  fi
fi

# ---------------------------------------------------------------- L'API de Hermes

step "L'API de Hermes"
if [ ! -f "$HENV" ]; then install -m 600 -o "$HUSER" -g "$(id -gn "$HUSER")" /dev/null "$HENV"; fi
HERMES_ENV_CHANGED=0
if [ "$(kv_get "$HENV" API_SERVER_ENABLED)" != "true" ]; then
  kv_set "$HENV" API_SERVER_ENABLED true
  HERMES_ENV_CHANGED=1
  ok "API de Hermes activée"
fi
if [ -z "$(kv_get "$HENV" API_SERVER_KEY)" ]; then
  kv_set "$HENV" API_SERVER_KEY "$(random_hex)"
  HERMES_ENV_CHANGED=1
  ok "clé de l'API créée"
fi
MCP_TOKEN=$(kv_get "$HENV" ORION_MCP_TOKEN)
if [ -z "$MCP_TOKEN" ]; then
  MCP_TOKEN=$(random_hex)
  kv_set "$HENV" ORION_MCP_TOKEN "$MCP_TOKEN"
  HERMES_ENV_CHANGED=1
fi
ok "sa clé reste sur ce serveur : Orion Sync la présente à Hermes à la place de celle de chaque appareil"

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

# La clé de Hermes, pour relayer vers lui ; jamais affichée. La clé de Hermes venue de l'extérieur est refusée : les
# appareils n'entrent qu'avec leur propre clé, reçue en se connectant avec le compte.
cat > "$SYNCF.new" <<EOF
DATABASE_URL=postgres://orion:$PG_PASSWORD@127.0.0.1:$PG_PORT/orion
HERMES_URL=http://127.0.0.1:$HERMES_PORT
HERMES_API_KEY=$(kv_get "$HENV" API_SERVER_KEY)
ACCEPT_HERMES_KEY=false
ACCOUNT_ISSUER=$ISSUER
ACCOUNT_SERVER_ID=$SERVER_ID
ACCOUNT_OWNER=$OWNER
HOST=127.0.0.1
PORT=$SYNC_PORT
ORION_MCP_TOKEN=$MCP_TOKEN
EOF
[ -z "$RELAY_KEY" ] || printf 'PUSH_RELAY_URL=%s\nPUSH_RELAY_KEY=%s\n' "$RELAY_URL" "$RELAY_KEY" >> "$SYNCF.new"
chmod 600 "$SYNCF.new"
mv "$SYNCF.new" "$SYNCF"
ok "configuration : $SYNCF (root seul)"

if [ "$PROFILES" = caddy ]; then
  cp "$DIR/app/bundle/Caddyfile" "$DIR/Caddyfile"
  kv_set "$ENVF" ORION_DOMAIN "$DOMAIN"
  if command -v ufw > /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp > /dev/null && ufw allow 443/tcp > /dev/null && note "pare-feu : 80 et 443 ouverts"
  fi
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
rm -f "$tmp/health"
for _ in $(seq 1 90); do
  curl -fsS "http://127.0.0.1:$SYNC_PORT/orion/v1/health" > "$tmp/health" 2>/dev/null && grep -q "\"version\":\"$VERSION\"" "$tmp/health" && break
  sleep 1
done
grep -qs "\"version\":\"$VERSION\"" "$tmp/health" || { docker logs --tail 30 orion-sync >&2 || true; die "Orion Sync $VERSION ne répond pas sur 127.0.0.1:$SYNC_PORT."; }
ok "Orion Sync répond ($(grep -o '"features":\[[^]]*\]' "$tmp/health"))"
grep -q '"accounts"' "$tmp/health" || warn "Orion Sync n'annonce pas « accounts » : le client ne pourra pas se connecter (docker logs orion-sync)."
# Le Caddyfile a pu changer (mise à jour) : Caddy le relit, sans couper les connexions.
if [ "$PROFILES" = caddy ]; then
  docker exec orion-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1 || docker restart orion-caddy > /dev/null
fi

# ---------------------------------------------------------------- nginx : tout vers Orion Sync

if [ -n "$NGINX_CONF" ]; then
  step "nginx : tout vers Orion Sync"
  stamp=$(date +%F-%H%M%S)
  install -d -m 700 /var/backups/orion-install
  backup="/var/backups/orion-install/$(basename "$NGINX_CONF").$stamp"
  cp -p "$NGINX_CONF" "$backup"
  snippet_backup=""
  if [ -f "$SNIPPET" ]; then
    snippet_backup="/var/backups/orion-install/orion-sync.conf.$stamp"
    cp -p "$SNIPPET" "$snippet_backup"
  fi
  restore() {
    cp -p "$backup" "$NGINX_CONF"
    if [ -n "$snippet_backup" ]; then cp -p "$snippet_backup" "$SNIPPET"; else rm -f "$SNIPPET"; fi
  }
  install -D -m 644 "$DIR/app/bundle/nginx-orion-sync.conf" "$SNIPPET"
  if ! grep -qE "snippets/orion-sync\.conf" "$NGINX_CONF"; then
    if grep -qE "location[[:space:]]+/orion/" "$NGINX_CONF"; then
      warn "$NGINX_CONF publie déjà /orion/ à la main : ferme-y /mcp/ toi-même (location /mcp/ { return 404; })."
    else
      # Avant le bloc location qui mène à Hermes.
      line=$(grep -nE "$TO_HERMES" "$NGINX_CONF" | head -n 1 | cut -d: -f1)
      at=$(head -n "$line" "$NGINX_CONF" | grep -nE "^[[:space:]]*location[[:space:]]" | tail -n 1 | cut -d: -f1)
      [ -n "$at" ] || { restore; die "bloc location de Hermes introuvable dans $NGINX_CONF : rien n'a changé."; }
      sed -i "${at}i\\    include $SNIPPET;" "$NGINX_CONF"
    fi
  fi
  # Ce qui menait à Hermes mène au service, qui relaie avec la clé de Hermes (src/proxy.ts).
  sed -i -E "s#proxy_pass([[:space:]]+)https?://(127\.0\.0\.1|localhost|\[::1\]):$HERMES_PORT\b#proxy_pass\1http://127.0.0.1:$SYNC_PORT#g" "$NGINX_CONF"
  if cmp -s "$backup" "$NGINX_CONF" && [ -n "$snippet_backup" ] && cmp -s "$snippet_backup" "$SNIPPET"; then
    ok "nginx mène déjà tout à Orion Sync ($NGINX_CONF)"
  elif nginx -t > "$tmp/nginx.log" 2>&1; then
    systemctl reload nginx
    ok "nginx : tout mène à Orion Sync, /mcp/ fermé ($NGINX_CONF ; avant : $backup)"
  else
    restore
    sed 's/^/    /' "$tmp/nginx.log" >&2
    die "nginx refuse la nouvelle configuration : l'ancienne est remise. Fais passer tout le site par 127.0.0.1:$SYNC_PORT à la main (modèle : $DIR/app/bundle/nginx-orion-sync.conf)."
  fi
fi

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
printf '  Compte  : %s (%s), chez %s\n' "$OWNER" "$SERVER_ID" "$ISSUER"
printf '  Le client se connecte dans Orion avec son e-mail : aucune clé à lui transmettre.\n'
[ -n "$RELAY_KEY" ] && printf '  Notifications : par le relais.\n' || printf '  Notifications : aucune (pas de clé de relais).\n'
[ "$MCP_OK" = 1 ] && printf '  Terminal du Mac : prêt (Réglages, « Ce Mac » dans l'"'"'app Mac).\n'
printf '  Mettre à jour : relance la même commande.\n'
