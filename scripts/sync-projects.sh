#!/usr/bin/env bash
# =====================================================================
#  sync-projects.sh [--dry-run]
#  Réconcilie l'état DÉSIRÉ (config/projects.yml) avec l'état RÉEL du VPS.
#   - deployed: true            → (re)déploie (deploy-project.sh)
#   - deployed: false / absent  → retire du VPS (remove-project.sh, data gardée)
#   - entrée disparue de la config → retire du VPS (backup + confirmation)
#   - renommage (même repo, name ≠) → signalé, migration si --apply-renames
#   - nettoie les vhosts générés orphelins
#   - régénère config/projects.md (vue lisible)
#  --dry-run : affiche le plan, ne modifie rien.
#  VLLDNT_ASSUME_YES=1 dans l'environnement → pas de question interactive
#  (utilisé par le workflow d'orchestration en mode "apply").
# =====================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

DRY=0; APPLY_RENAMES=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1;;
    --apply-renames) APPLY_RENAMES=1;;
    *) die "argument inconnu : $a";;
  esac
done
log_init "sync-projects" "$@"
require_cmd git yq nginx
cfg_check

DESIRED_ALL="$(cfg_names | sort || true)"
DESIRED_ON=""
for n in $DESIRED_ALL; do cfg_deployed "$n" && DESIRED_ON+="$n"$'\n'; done
ACTUAL="$(
  {
    for d in "$PROJECTS_DIR" "$LANDING_DIR"; do
      [[ -d "$d" ]] || continue
      for e in "$d"/*; do [[ -e "$e" ]] && printf '%s\n' "${e##*/}"; done
    done
    for f in "$NGINX_GEN"/apps/*.conf "$NGINX_GEN"/landings/*.conf; do
      [[ -e "$f" ]] || continue
      b="${f##*/}"; printf '%s\n' "${b%.conf}"
    done
  } | sort -u
)"

step "PLAN"
declare -a TO_DEPLOY TO_DISABLE TO_REMOVE RENAMES
for n in $DESIRED_ON;  do TO_DEPLOY+=("$n"); done
for n in $ACTUAL; do
  if grep -qx "$n" <<<"$DESIRED_ALL"; then
    cfg_deployed "$n" || TO_DISABLE+=("$n")          # présent en config mais deployed:false
  else
    # Absent de la config. Renommage ? (même origin git qu'une entrée connue)
    old_remote=""
    [[ -f "$PROJECTS_DIR/$n/src/.git/config" ]] && old_remote="$(git -C "$PROJECTS_DIR/$n/src" remote get-url origin 2>/dev/null || true)"
    match=""
    if [[ -n "$old_remote" ]]; then
      for d in $DESIRED_ALL; do
        [[ "$(cfg_field "$d" repo)" == "$old_remote" ]] && ! grep -qx "$d" <<<"$ACTUAL" && match="$d" && break
      done
    fi
    if [[ -n "$match" ]]; then RENAMES+=("$n=>$match"); else TO_REMOVE+=("$n"); fi
  fi
done

printf '  déployer / mettre à jour : %s\n' "${TO_DEPLOY[*]:-(aucun)}"
printf '  désactiver (deployed:false): %s\n' "${TO_DISABLE[*]:-(aucun)}"
printf '  supprimer (retiré de la config): %s\n' "${TO_REMOVE[*]:-(aucun)}"
printf '  renommages détectés : %s\n' "${RENAMES[*]:-(aucun)}"

if ((DRY)); then
  log "--dry-run : aucune modification."
  exit 0
fi

step "APPLICATION"
rc=0

for n in "${TO_DEPLOY[@]:-}"; do
  [[ -z "$n" ]] && continue
  "$SCRIPTS_DIR/deploy-project.sh" "$n" || { warn "échec deploy : $n"; rc=1; }
done

for n in "${TO_DISABLE[@]:-}"; do
  [[ -z "$n" ]] && continue
  log "désactivation (deployed:false) : $n"
  VLLDNT_ASSUME_YES="${VLLDNT_ASSUME_YES:-0}" "$SCRIPTS_DIR/remove-project.sh" "$n" --confirm --reason "deployed:false" || rc=1
done

for pair in "${RENAMES[@]:-}"; do
  [[ -z "$pair" ]] && continue
  old="${pair%%=>*}"; new="${pair##*=>}"
  if ((APPLY_RENAMES)); then
    log "renommage : $old → $new"
    [[ -d "$PROJECTS_DIR/$old" ]] && { mkdir -p "$PROJECTS_DIR/$new"; rsync -a --delete "$PROJECTS_DIR/$old/" "$PROJECTS_DIR/$new/"; }
    [[ -d "$LANDING_DIR/$old" ]]  && { rm -rf "$LANDING_DIR/$new"; mv -T "$LANDING_DIR/$old" "$LANDING_DIR/$new"; }
    [[ -d "$DATA_DIR/$old" ]]     && { rm -rf "$DATA_DIR/$new"; mv -T "$DATA_DIR/$old" "$DATA_DIR/$new"; }
    safe_rm "$PROJECTS_DIR/$old" "$NGINX_GEN/apps/$old.conf" "$NGINX_GEN/landings/$old.conf"
    "$SCRIPTS_DIR/deploy-project.sh" "$new" || rc=1
  else
    warn "renommage $old → $new NON appliqué (relancer avec --apply-renames)"
  fi
done

for n in "${TO_REMOVE[@]:-}"; do
  [[ -z "$n" ]] && continue
  log "suppression (retiré de projects.yml) : $n"
  "$SCRIPTS_DIR/remove-project.sh" "$n" --confirm --reason "retiré de projects.yml" || rc=1
done

nginx_reload

# --- projects.md (vue lisible, générée) --------------------------
step "génération de projects.md"
{
  echo "<!-- GÉNÉRÉ par sync-projects.sh — NE PAS ÉDITER -->"
  echo "# Projets — $DOMAIN"
  echo
  echo "| Nom | Dépôt | Déployé | Runtime | Landing | URLs |"
  echo "|-----|-------|:-------:|---------|:-------:|------|"
  for n in $DESIRED_ALL; do
    repo="$(cfg_field "$n" repo)"; repo="${repo#https://github.com/}"; repo="${repo%.git}"
    dep="$(cfg_deployed "$n" && echo oui || echo non)"
    rt="$(cfg_field "$n" runtime static)"
    lp="$([[ -d "$LANDING_DIR/$n" ]] && echo oui || echo —)"
    echo "| \`$n\` | $repo | $dep | $rt | $lp | app: \`$n.$DOMAIN\` · landing: \`$DOMAIN/$n\` |"
  done
  echo
  echo "_Généré le $(date -u +%Y-%m-%dT%H:%M:%SZ)._"
} > "$CONFIG_DIR/projects.md"
cp "$CONFIG_DIR/projects.md" "$PORTFOLIO_DIR/src/projects.md" 2>/dev/null || true
log "projects.md régénéré"

log "=== terminé (rc=$rc)"
exit "$rc"
