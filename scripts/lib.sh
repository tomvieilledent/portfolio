#!/usr/bin/env bash
# =====================================================================
#  lib.sh — fonctions communes aux scripts de déploiement vlldnt.fr
#  Sourcé par les autres scripts. Ne s'exécute pas seul.
# =====================================================================

# --- Emplacements (surchargeables par l'environnement) ---------------
VLLDNT_ROOT="${VLLDNT_ROOT:-/opt/vlldnt}"
DOMAIN="${VLLDNT_DOMAIN:-vlldnt.fr}"
PORTFOLIO_DIR="$VLLDNT_ROOT/portfolio"
PROJECTS_DIR="$VLLDNT_ROOT/projects"
LANDING_DIR="$VLLDNT_ROOT/landing-pages"
CONFIG_DIR="$VLLDNT_ROOT/config"
DATA_DIR="$VLLDNT_ROOT/data"
SCRIPTS_DIR="$VLLDNT_ROOT/scripts"
BACKUP_DIR="$VLLDNT_ROOT/backups"
LOG_DIR="$VLLDNT_ROOT/logs"
NGINX_DIR="$VLLDNT_ROOT/nginx"
NGINX_TMPL="$NGINX_DIR/templates"
NGINX_GEN="$NGINX_DIR/generated"
NGINX_SNIPPETS="$NGINX_DIR/snippets"
CONFIG_FILE="$CONFIG_DIR/projects.yml"

RELEASES_KEEP="${RELEASES_KEEP:-5}"
LETSENCRYPT_LIVE="/etc/letsencrypt/live/$DOMAIN"

# CSP par défaut des apps (surchargeable par `csp:` dans projects.yml).
DEFAULT_CSP="default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'"

# Noms de projet interdits (collisions de chemin / route).
RESERVED_NAMES=" portfolio www config scripts data logs backups nginx projects landing-pages api assets .well-known "

# --- Journalisation -------------------------------------------------
_LOG_FILE=""
log_init() {  # $1 = nom court du script
  mkdir -p "$LOG_DIR"
  _LOG_FILE="$LOG_DIR/${1}-$(date +%Y%m%d-%H%M%S).log"
  # stderr (toute la journalisation) → fichier de log + terminal.
  # stdout reste propre pour les valeurs renvoyées par les fonctions.
  exec 2> >(tee -a "$_LOG_FILE" >&2)
  log "=== ${1} — $(date -u +%Y-%m-%dT%H:%M:%SZ) — args: ${*:2}"
}
# Toute la journalisation part sur stderr : ainsi les fonctions utilisées en
# $(...) (build_static, backup_paths…) ne renvoient QUE leur résultat sur stdout.
# log_init redirige stderr vers le fichier de log + le terminal.
log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '%s  \033[33mWARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '%s  \033[31mERREUR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit "${2:-1}"; }
step() { printf '\n\033[36m▶ %s\033[0m\n' "$*" >&2; }

# --- Garde-fous ----------------------------------------------------
require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "commande absente : $c"; done
}

# Valide un nom de projet. Sert aux URLs, aux chemins et aux noms de
# conteneurs — donc strict : minuscules, chiffres, tirets, 2 à 39 car.
validate_name() {
  local n="${1:-}"
  [[ -n "$n" ]]                        || die "nom de projet vide"
  [[ "$n" =~ ^[a-z][a-z0-9-]{1,38}$ ]] || die "nom invalide : « $n » (attendu ^[a-z][a-z0-9-]{1,38}\$)"
  [[ "$n" != *".."* && "$n" != *"/"* ]] || die "nom invalide : « $n »"
  [[ "$RESERVED_NAMES" != *" $n "* ]]  || die "nom réservé : « $n »"
}

# Vérifie qu'un chemin est bien SOUS $VLLDNT_ROOT avant toute suppression.
assert_under_root() {
  local p; p="$(realpath -m -- "$1")"
  [[ "$p" == "$VLLDNT_ROOT"/* ]] || die "refus : « $p » hors de $VLLDNT_ROOT"
}

safe_rm() {  # rm -rf borné à $VLLDNT_ROOT
  local t
  for t in "$@"; do
    [[ -e "$t" || -L "$t" ]] || continue
    assert_under_root "$t"
    rm -rf -- "$t"
    log "supprimé : $t"
  done
}

# --- Lecture de projects.yml (yq v4 / mikefarah — idiome env()) -----
cfg_check() {
  [[ -f "$CONFIG_FILE" ]] || die "config absente : $CONFIG_FILE"
  local tag
  tag="$(yq '.projects | tag' "$CONFIG_FILE" 2>/dev/null || echo err)"
  [[ "$tag" == "!!seq" ]] \
    || die "projects.yml invalide ou sans liste .projects (tag=$tag) — abandon, aucune modification"
}
cfg_names() { yq '.projects[].name' "$CONFIG_FILE"; }
cfg_has() {   # $1=name
  local o; o="$(CFG_N="$1" yq '.projects[] | select(.name == env(CFG_N)) | .name' "$CONFIG_FILE" 2>/dev/null)"
  [[ -n "$o" ]]
}
cfg_field() { # $1=name  $2=champ  $3=défaut
  local v
  v="$(CFG_N="$1" CFG_F="$2" yq '(.projects[] | select(.name == env(CFG_N)) | .[env(CFG_F)]) // ""' "$CONFIG_FILE" 2>/dev/null)"
  [[ -n "$v" && "$v" != "null" ]] && printf '%s' "$v" || printf '%s' "${3:-}"
}
cfg_deployed() { [[ "$(cfg_field "$1" deployed false)" == "true" ]]; }

# --- Nginx --------------------------------------------------------
render_template() { # $1=template  $2=sortie  puis paires clé valeur
  local tmpl="$1" out="$2"; shift 2
  [[ -f "$tmpl" ]] || die "template absent : $tmpl"
  local content; content="$(cat "$tmpl")"
  while (($#)); do content="${content//@@$1@@/$2}"; shift 2; done
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$content" > "$out"
}

nginx_reload() {
  step "nginx : test + reload"
  sudo nginx -t || die "nginx -t a échoué — configuration non rechargée"
  sudo systemctl reload nginx
  log "nginx rechargé"
}

# --- Symlink de release atomique --------------------------------
promote_release() { # $1=dossier projet (contient releases/)  $2=timestamp
  local base="$1" ts="$2" tmp
  tmp="$base/.current.$$"
  ln -s "releases/$ts" "$tmp"
  mv -Tf "$tmp" "$base/current"
  # purge : ne garder que les RELEASES_KEEP plus récentes
  ( cd "$base/releases" && ls -1dt */ 2>/dev/null | tail -n "+$((RELEASES_KEEP+1))" \
      | while read -r d; do rm -rf -- "$d"; done ) || true
}

# --- Backup tar --------------------------------------------------
backup_paths() { # $1=préfixe nom d'archive ; $@ = chemins à archiver
  local name="$1"; shift
  mkdir -p "$BACKUP_DIR"
  local arc="$BACKUP_DIR/${name}-$(date +%Y%m%d-%H%M%S).tar.gz"
  local existing=(); local p
  for p in "$@"; do [[ -e "$p" || -L "$p" ]] && existing+=("$p"); done
  if ((${#existing[@]})); then
    tar czf "$arc" --absolute-names "${existing[@]}" 2>/dev/null || warn "tar partiel : $arc"
    log "backup : $arc"
    printf '%s' "$arc"
  else
    log "backup : rien à archiver pour $name"
  fi
}

# --- Build statique générique ----------------------------------
# Construit le dossier $1 (git working tree), renvoie le chemin du
# dossier de sortie à publier (echo) — soit le build, soit le dossier
# lui-même si aucun build n'est nécessaire.
build_static() { # $1=src  $2=build_cmd(""=auto)  $3=output("")
  local src="$1" cmd="$2" out="$3"
  if [[ -z "$cmd" && -f "$src/package.json" ]]; then
    if [[ -f "$src/package-lock.json" ]]; then
      cmd="npm ci --no-audit --no-fund && npm run build"
    else
      cmd="npm install --no-audit --no-fund && npm run build"
    fi
  fi
  local dir
  if [[ -n "$cmd" ]]; then
    log "build : $cmd"
    # Sortie du build → stderr : cette fonction est appelée en $(...) et ne
    # doit renvoyer QUE le chemin du dossier de sortie sur stdout.
    ( cd "$src" && eval "$cmd" ) >&2 || die "build échoué dans $src"
    dir="$src/${out:-dist}"
  else
    dir="$src"                       # pas de build : on publie le dépôt tel quel
  fi
  [[ -f "$dir/index.html" ]] || die "sortie sans index.html : $dir"
  printf '%s' "$dir"
}

# --- Git working tree sur une branche donnée ------------------
sync_repo() { # $1=url  $2=branch  $3=dest
  local url="$1" br="$2" dest="$3"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" remote set-url origin "$url"
    git -C "$dest" fetch --depth 1 origin "$br"
    git -C "$dest" checkout -q -B "$br" "origin/$br"
    git -C "$dest" reset --hard -q "origin/$br"
    git -C "$dest" clean -fdxq -e node_modules
  else
    mkdir -p "$(dirname "$dest")"
    git clone --depth 1 --branch "$br" "$url" "$dest"
  fi
  git -C "$dest" rev-parse --short HEAD
}
