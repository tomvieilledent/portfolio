#!/usr/bin/env bash
# =====================================================================
#  healthcheck.sh
#  Vérifie : apex, chaque sous-domaine déployé, chaque landing, l'état
#  des conteneurs compose, et l'expiration du certificat.
#  Code retour ≠ 0 si une vérification critique échoue.
# =====================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
log_init "healthcheck"
require_cmd curl yq

rc=0
check() { # $1=url  $2=attendu(défaut 200)
  local url="$1" want="${2:-200}" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo 000)"
  if [[ "$code" == "$want" ]]; then log "  OK  $url → $code"
  else warn "  KO  $url → $code (attendu $want)"; rc=1; fi
}

step "apex"
check "https://$DOMAIN"
check "http://$DOMAIN" 301

if [[ -f "$CONFIG_FILE" ]]; then
  step "projets déployés"
  for n in $(cfg_names); do
    cfg_deployed "$n" || continue
    check "https://$n.$DOMAIN"
    [[ -d "$LANDING_DIR/$n" ]] && check "https://$DOMAIN/$n/"
    if [[ "$(cfg_field "$n" runtime static)" == compose ]] && command -v docker >/dev/null; then
      st="$(docker compose -p "vlldnt-$n" ps --status running -q 2>/dev/null | wc -l)"
      [[ "$st" -ge 1 ]] && log "  OK  conteneurs vlldnt-$n : $st actif(s)" || { warn "  KO  aucun conteneur actif pour vlldnt-$n"; rc=1; }
    fi
  done
fi

step "certificat TLS"
if [[ -f "$LETSENCRYPT_LIVE/fullchain.pem" ]] && command -v openssl >/dev/null; then
  end="$(openssl x509 -enddate -noout -in "$LETSENCRYPT_LIVE/fullchain.pem" | cut -d= -f2)"
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  [[ "$days" -gt 21 ]] && log "  OK  expire dans $days j ($end)" || { warn "  KO  expire dans $days j — vérifier le renouvellement"; rc=1; }
else
  warn "  ?   certificat introuvable : $LETSENCRYPT_LIVE/fullchain.pem"
fi

step "résumé"
[[ "$rc" == 0 ]] && log "tout est vert." || warn "au moins une vérification a échoué."
exit "$rc"
