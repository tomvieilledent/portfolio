#!/usr/bin/env bash
# =====================================================================
#  remove-project.sh <nom> [--confirm] [--purge-data] [--reason "..."]
#  Suppression SÉCURISÉE d'un projet du VPS :
#   - sans --confirm : mode simulation (dry-run), n'affiche que le plan.
#   - avec --confirm : backup tar, puis suppression app + landing + vhosts
#                      + conteneurs. Les données (data/<nom>) sont
#                      DÉPLACÉES dans backups/orphan-data/ sauf --purge-data.
#   - confirmation interactive (saisie du nom) sauf VLLDNT_ASSUME_YES=1.
# =====================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

NAME="${1:-}"; shift || true
CONFIRM=0; PURGE=0; REASON="(non précisé)"
while (($#)); do
  case "$1" in
    --confirm) CONFIRM=1;;
    --purge-data) PURGE=1;;
    --reason) REASON="${2:-}"; shift;;
    *) die "argument inconnu : $1";;
  esac; shift
done
validate_name "$NAME"
log_init "remove-project" "$NAME ($REASON)"
require_cmd nginx

PROOT="$PROJECTS_DIR/$NAME"
LAND="$LANDING_DIR/$NAME"
DATA="$DATA_DIR/$NAME"
ENVF="$CONFIG_DIR/$NAME.env"
VHOST_APP="$NGINX_GEN/apps/$NAME.conf"
VHOST_LAND="$NGINX_GEN/landings/$NAME.conf"
CONTAINERS="$(docker ps -a --filter "label=com.docker.compose.project=vlldnt-$NAME" -q 2>/dev/null || true)"
VOLUMES="$(docker volume ls -q --filter "label=com.docker.compose.project=vlldnt-$NAME" 2>/dev/null || true)"

step "ÉLÉMENTS CONCERNÉS PAR LA SUPPRESSION DE « $NAME »"
printf '  raison            : %s\n' "$REASON"
printf '  application       : %s\n' "$( [[ -d $PROOT ]] && echo "$PROOT" || echo '—')"
printf '  landing page      : %s\n' "$( [[ -d $LAND ]] && echo "$LAND" || echo '—')"
printf '  vhost app         : %s\n' "$( [[ -f $VHOST_APP ]] && echo "$VHOST_APP" || echo '—')"
printf '  vhost landing     : %s\n' "$( [[ -f $VHOST_LAND ]] && echo "$VHOST_LAND" || echo '—')"
printf '  secrets .env      : %s\n' "$( [[ -f $ENVF ]] && echo "$ENVF (archivé, non supprimé du backup)" || echo '—')"
printf '  conteneurs docker : %s\n' "${CONTAINERS:-—}"
printf '  volumes docker    : %s\n' "${VOLUMES:-—}"
printf '  données data/     : %s\n' "$( [[ -d $DATA ]] && echo "$DATA → $( ((PURGE)) && echo 'SUPPRIMÉES (--purge-data)' || echo 'déplacées dans backups/orphan-data/')" || echo '—')"
printf '  sous-domaine      : https://%s.%s ne répondra plus\n' "$NAME" "$DOMAIN"
printf '  route             : https://%s/%s ne répondra plus\n' "$DOMAIN" "$NAME"

if ! ((CONFIRM)); then
  echo
  warn "SIMULATION (dry-run). Rien n'a été supprimé."
  log  "Pour exécuter réellement : $0 $NAME --confirm$( ((PURGE)) && printf ' --purge-data' )"
  exit 0
fi

if [[ "${VLLDNT_ASSUME_YES:-0}" != 1 ]]; then
  echo
  read -r -p "Confirmer la suppression — retape le nom du projet (« $NAME ») : " ans
  [[ "$ans" == "$NAME" ]] || die "saisie « $ans » ≠ « $NAME » — abandon."
fi

step "backup"
ARC="$(backup_paths "removed-$NAME" "$PROOT" "$LAND" "$DATA" "$ENVF" "$VHOST_APP" "$VHOST_LAND")"

step "arrêt des conteneurs"
if [[ -n "$CONTAINERS" || -n "$VOLUMES" ]]; then
  if ((PURGE)); then docker compose -p "vlldnt-$NAME" down -v --remove-orphans 2>/dev/null || true
  else               docker compose -p "vlldnt-$NAME" down    --remove-orphans 2>/dev/null || true; fi
  # filet de sécurité si compose n'a pas tout pris
  [[ -n "$CONTAINERS" ]] && docker rm -f $CONTAINERS 2>/dev/null || true
fi

step "suppression des fichiers"
safe_rm "$PROOT" "$LAND" "$VHOST_APP" "$VHOST_LAND"
if [[ -d "$DATA" ]]; then
  if ((PURGE)); then safe_rm "$DATA"
  else
    mkdir -p "$BACKUP_DIR/orphan-data"
    mv -T "$DATA" "$BACKUP_DIR/orphan-data/$NAME-$(date +%Y%m%d-%H%M%S)"
    log "données déplacées dans $BACKUP_DIR/orphan-data/"
  fi
fi
# .env : conservé hors backup courant ? non — on l'archive puis on le retire.
safe_rm "$ENVF"

nginx_reload

printf '%s\t%s\tremove\treason=%s\tbackup=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$REASON" "${ARC:-none}" >> "$BACKUP_DIR/removals.log"
log "=== « $NAME » retiré du VPS. Backup : ${ARC:-aucun}"
