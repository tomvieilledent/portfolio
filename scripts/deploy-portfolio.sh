#!/usr/bin/env bash
# =====================================================================
#  deploy-portfolio.sh
#  Met à jour le site perso (vlldnt.fr) ET l'infra du domaine :
#   1. git pull du dépôt portfolio dans /opt/vlldnt/portfolio/src
#   2. réinstalle scripts + templates nginx + snippet + projects.yml
#   3. docker compose up (conteneur nginx+dist Astro, port loopback)
#   4. (re)génère le vhost apex (proxy_pass vers le conteneur) et recharge nginx
#  Le premier clone est fait par VPS-BOOTSTRAP.md.
# =====================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
log_init "deploy-portfolio"
require_cmd git yq nginx rsync docker

SRC="$PORTFOLIO_DIR/src"
[[ -d "$SRC/.git" ]] || die "dépôt portfolio absent : $SRC (voir VPS-BOOTSTRAP.md)"

step "git pull ($(git -C "$SRC" remote get-url origin))"
BR="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
git -C "$SRC" fetch --depth 1 origin "$BR"
git -C "$SRC" reset --hard -q "origin/$BR"
git -C "$SRC" clean -fdxq -e node_modules
log "HEAD = $(git -C "$SRC" rev-parse --short HEAD)"

step "réinstallation de l'infra"
install -d "$SCRIPTS_DIR" "$NGINX_TMPL" "$NGINX_SNIPPETS" "$NGINX_GEN/apps" "$NGINX_GEN/landings" "$CONFIG_DIR"
install -m 755 "$SRC"/scripts/*.sh                                "$SCRIPTS_DIR/"
install -m 644 "$SRC"/deploy/nginx/*.tmpl                          "$NGINX_TMPL/"
install -m 644 "$SRC"/deploy/nginx/vlldnt-security-headers.conf    "$NGINX_SNIPPETS/security-headers.conf"
install -m 644 "$SRC"/deploy/nginx/vlldnt.conf.base               "$NGINX_DIR/vlldnt.conf"
# projects.yml : on ne l'écrase que s'il a changé (préserve un éventuel edit VPS validé).
if ! cmp -s "$SRC/projects.yml" "$CONFIG_FILE"; then
  cp "$SRC/projects.yml" "$CONFIG_FILE"; log "projects.yml mis à jour"
fi

step "docker compose up (portfolio, port loopback)"
PORT="$(yq '.portfolio.port // 8086' "$SRC/projects.yml" 2>/dev/null || echo 8086)"
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || die "champ portfolio.port invalide"
PORT="$PORT" docker compose -p vlldnt-portfolio -f "$SRC/compose.yml" up -d --build --remove-orphans
log "publié : conteneur vlldnt-portfolio sur 127.0.0.1:$PORT"

nginx_reload

step "réconciliation des projets"
"$SCRIPTS_DIR/sync-projects.sh" || warn "sync-projects.sh a signalé un problème — voir son log"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN" || true)"
[[ "$code" == 200 ]] && log "https://$DOMAIN → $code ✅" || warn "https://$DOMAIN → $code"
log "=== terminé"
