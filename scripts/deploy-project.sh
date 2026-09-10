#!/usr/bin/env bash
# =====================================================================
#  deploy-project.sh <nom> [--force]
#  (Re)déploie un projet SI son entrée projects.yml a deployed: true.
#  - runtime static  : git → build → releases/<ts> → symlink current
#  - runtime compose : git → docker compose up -d --build → proxy_pass
#  Détecte une landing-page/ optionnelle et la publie sous vlldnt.fr/<nom>.
# =====================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

NAME="${1:-}"; FORCE="${2:-}"
validate_name "$NAME"
log_init "deploy-project" "$NAME"
require_cmd git yq nginx
cfg_check

# --- Garde : ne rien faire si le projet n'est pas "deployed: true" ---
if ! cfg_has "$NAME"; then
  log "« $NAME » absent de projects.yml — rien à faire."; exit 0
fi
if ! cfg_deployed "$NAME"; then
  log "« $NAME » a deployed != true — déploiement ignoré (voir sync-projects.sh pour le retirer du VPS)."
  exit 0
fi

REPO="$(cfg_field "$NAME" repo)";      [[ -n "$REPO" ]] || die "champ repo manquant pour $NAME"
BRANCH="$(cfg_field "$NAME" branch main)"
RUNTIME="$(cfg_field "$NAME" runtime static)"
CSP="$(cfg_field "$NAME" csp "$DEFAULT_CSP")"
PROOT="$PROJECTS_DIR/$NAME"
SRC="$PROOT/src"
mkdir -p "$PROOT/releases"

step "récupération du dépôt ($REPO @ $BRANCH)"
SHA="$(sync_repo "$REPO" "$BRANCH" "$SRC")"
log "HEAD = $SHA"

case "$RUNTIME" in
  static)
    step "build statique"
    BUILT="$(build_static "$SRC" "$(cfg_field "$NAME" build)" "$(cfg_field "$NAME" output)")"
    TS="$(date +%Y%m%d-%H%M%S)-$$"
    rm -rf "$PROOT/releases/$TS"; mkdir -p "$PROOT/releases/$TS"
    cp -a "$BUILT/." "$PROOT/releases/$TS/"
    [[ -f "$PROOT/releases/$TS/index.html" ]] || die "release sans index.html : $PROOT/releases/$TS"
    promote_release "$PROOT" "$TS"
    log "publié : $PROOT/current -> releases/$TS ($SHA)"
    render_template "$NGINX_TMPL/app.static.tmpl" "$NGINX_GEN/apps/$NAME.conf" NAME "$NAME" CSP "$CSP"
    ;;
  compose)
    require_cmd docker
    PORT="$(cfg_field "$NAME" port)"; [[ "$PORT" =~ ^[0-9]{2,5}$ ]] || die "champ port requis (loopback) pour runtime compose"
    CF="$(cfg_field "$NAME" compose_file compose.yml)"
    [[ -f "$SRC/$CF" ]] || die "compose introuvable : $SRC/$CF"
    ENVF="$CONFIG_DIR/$NAME.env"
    if [[ ! -f "$ENVF" ]]; then warn "secrets absents : $ENVF (créé vide)"; : > "$ENVF"; chmod 600 "$ENVF"; fi
    step "docker compose up (projet vlldnt-$NAME, port loopback $PORT)"
    docker compose -p "vlldnt-$NAME" -f "$SRC/$CF" --env-file "$ENVF" up -d --build --remove-orphans
    echo "$SHA $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PROOT/.deployed_sha"
    render_template "$NGINX_TMPL/app.compose.tmpl" "$NGINX_GEN/apps/$NAME.conf" NAME "$NAME" PORT "$PORT" CSP "$CSP"
    ;;
  *) die "runtime inconnu : « $RUNTIME » (static|compose)";;
esac

# --- Landing page (optionnelle) ------------------------------------
step "landing-page"
if [[ -d "$SRC/landing-page" ]]; then
  LBUILT="$(build_static "$SRC/landing-page" "$(cfg_field "$NAME" landing_build)" "$(cfg_field "$NAME" landing_output)")"
  TMP="$LANDING_DIR/.$NAME.$$"
  rm -rf "$TMP"; mkdir -p "$TMP"; cp -a "$LBUILT/." "$TMP/"
  [[ -f "$TMP/index.html" ]] || die "landing sans index.html : $LBUILT"
  rm -rf "$LANDING_DIR/$NAME"; mv -T "$TMP" "$LANDING_DIR/$NAME"
  render_template "$NGINX_TMPL/landing.location.tmpl" "$NGINX_GEN/landings/$NAME.conf" NAME "$NAME"
  log "landing publiée : vlldnt.fr/$NAME"
else
  safe_rm "$LANDING_DIR/$NAME" "$NGINX_GEN/landings/$NAME.conf"
  log "pas de landing-page/ dans le dépôt — ignorée."
fi

nginx_reload

step "vérification"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$NAME.$DOMAIN" || true)"
[[ "$code" == 200 ]] && log "https://$NAME.$DOMAIN → $code ✅" || warn "https://$NAME.$DOMAIN → $code (DNS/HSTS/propagation ?)"
log "=== terminé : $NAME ($SHA)"
