#!/usr/bin/env bash
# =====================================================================
#  rollback.sh <nom|portfolio> [--steps N]   (défaut N=1)
#  Revient à une release antérieure.
#   - static  : repointe le symlink "current" vers releases/<N-ième plus récente>
#   - compose : recheckout du SHA précédent depuis .deployed_sha + rebuild
# =====================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

TARGET="${1:-}"; STEPS=1
[[ "${2:-}" == "--steps" ]] && STEPS="${3:-1}"
[[ -n "$TARGET" ]] || die "usage : rollback.sh <nom|portfolio> [--steps N]"
[[ "$STEPS" =~ ^[0-9]+$ && "$STEPS" -ge 1 ]] || die "N invalide"
log_init "rollback" "$TARGET steps=$STEPS"
require_cmd nginx

if [[ "$TARGET" == portfolio ]]; then
  BASE="$PORTFOLIO_DIR"; RUNTIME=static
else
  validate_name "$TARGET"; BASE="$PROJECTS_DIR/$TARGET"
  if [[ -f "$CONFIG_FILE" ]]; then RUNTIME="$(cfg_field "$TARGET" runtime static)"; else RUNTIME=static; fi
fi
[[ -d "$BASE" ]] || die "projet inconnu sur le VPS : $BASE"

case "$RUNTIME" in
  static)
    mapfile -t REL < <(cd "$BASE/releases" && ls -1dt */ 2>/dev/null | sed 's#/##')
    (( ${#REL[@]} > STEPS )) || die "pas assez de releases (${#REL[@]}) pour reculer de $STEPS"
    cur="$(basename "$(readlink -f "$BASE/current")")"
    idx=0; for i in "${!REL[@]}"; do [[ "${REL[$i]}" == "$cur" ]] && idx=$i && break; done
    tgt="${REL[$((idx+STEPS))]}"
    step "rollback $TARGET : $cur → $tgt"
    promote_release "$BASE" "$tgt"
    ;;
  compose)
    require_cmd docker git
    [[ -f "$BASE/.deployed_sha" ]] || die "pas d'historique .deployed_sha"
    sha="$(tail -n $((STEPS+1)) "$BASE/.deployed_sha" | head -n1 | awk '{print $1}')"
    [[ -n "$sha" ]] || die "SHA introuvable à -$STEPS"
    step "rollback $TARGET : recheckout $sha + rebuild"
    git -C "$BASE/src" checkout -q "$sha"
    CF="$(cfg_field "$TARGET" compose_file compose.yml)"
    docker compose -p "vlldnt-$TARGET" -f "$BASE/src/$CF" --env-file "$CONFIG_DIR/$TARGET.env" up -d --build
    echo "$sha $(date -u +%Y-%m-%dT%H:%M:%SZ) (rollback)" >> "$BASE/.deployed_sha"
    ;;
esac

nginx_reload
log "=== rollback terminé"
