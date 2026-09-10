#!/usr/bin/env bash
# =====================================================================
#  deploy-all.sh
#  (Re)déploie tous les projets marqués deployed: true dans projects.yml.
#  Un échec sur un projet n'interrompt pas les autres ; code retour ≠ 0
#  si au moins un projet a échoué.
# =====================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
log_init "deploy-all"
require_cmd git yq nginx
cfg_check

rc=0; ok=(); ko=()
for n in $(cfg_names); do
  cfg_deployed "$n" || { log "· $n : deployed:false — ignoré"; continue; }
  step "projet : $n"
  if "$SCRIPTS_DIR/deploy-project.sh" "$n"; then ok+=("$n"); else ko+=("$n"); rc=1; fi
done

step "résumé"
log "OK  (${#ok[@]}) : ${ok[*]:-—}"
log "KO  (${#ko[@]}) : ${ko[*]:-—}"
exit "$rc"
