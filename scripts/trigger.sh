#!/bin/bash
set -euo pipefail

# ============================================================
# trigger.sh — Active ou désactive un scénario de chaos engineering
# Usage :
#   ./trigger.sh start <numero>    # active le scénario
#   ./trigger.sh stop <numero>     # désactive le scénario
#   ./trigger.sh stop-all          # désactive TOUS les scénarios
#   ./trigger.sh status            # affiche l'état de tous les scénarios
#
# Exemples :
#   ./trigger.sh start 1           # active le scénario 1 (quorum)
#   ./trigger.sh start 8           # active le scénario 8 (combiné, 2 ressources)
#   ./trigger.sh stop 1            # désactive le scénario 1
#   ./trigger.sh stop-all          # reset complet, tous scénarios désactivés
# ============================================================

CHAOS_NS="university-chaos"
APP_NS="university-app"

log()  { echo -e "\n\033[1;34m[chaos]\033[0m $1"; }
ok()   { echo -e "\033[1;32m  ✓ $1\033[0m"; }
err()  { echo -e "\033[1;31m  ✗ $1\033[0m"; exit 1; }
warn() { echo -e "\033[1;33m  ⚠ $1\033[0m"; }

# Vérifie que Chaos Mesh est installé
check_chaos_mesh() {
  if ! kubectl get crd podchaos.chaos-mesh.org &>/dev/null; then
    err "Chaos Mesh n'est pas installé. Lance d'abord ./setup-chaos.sh"
  fi
}

# Active un scénario (suspend: false)
activate() {
  local resource_type=$1
  local resource_name=$2
  kubectl patch "${resource_type}" "${resource_name}" \
    -n "${CHAOS_NS}" \
    --type merge \
    -p '{"spec":{"suspend":false}}'
  ok "${resource_type}/${resource_name} activé"
}

# Désactive un scénario (suspend: true)
deactivate() {
  local resource_type=$1
  local resource_name=$2
  kubectl patch "${resource_type}" "${resource_name}" \
    -n "${CHAOS_NS}" \
    --type merge \
    -p '{"spec":{"suspend":true}}' 2>/dev/null || true
  ok "${resource_type}/${resource_name} désactivé"
}

# Attente observable — affiche les métriques clés pendant la durée de la panne
watch_metrics() {
  local scenario=$1
  local duration=${2:-60}
  log "Observation en cours (${duration}s) — Ctrl+C pour arrêter"
  echo "  → Dashboard Grafana : http://grafana.university.local:8080"
  echo "  → Pods en temps réel :"
  for i in $(seq 1 "${duration}"); do
    printf "\r  [%02ds/%02ds] Pods: " "$i" "$duration"
    kubectl get pods -n "${APP_NS}" \
      --no-headers \
      -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready' \
      2>/dev/null | tr '\n' ' | ' | head -c 120
    sleep 1
  done
  echo ""
}

start_scenario() {
  local scenario=$1
  check_chaos_mesh

  case "${scenario}" in
    1)
      log "Scénario 1 — Violation du quorum (kill 1 pod enrollment-service)"
      warn "Le HPA va recréer le pod — observe la fenêtre de vulnérabilité dans Grafana"
      activate podchaos scenario-1-quorum-violation
      watch_metrics 1 60
      ;;
    2)
      log "Scénario 2 — Rollback incompatible avec schéma DB"
      warn "Pré-requis : enrollment-service v2 déployé + migration Alembic appliquée"
      warn "             + table de compatibilité du moteur mise à jour"
      read -p "  Ces pré-requis sont satisfaits ? (y/N) " confirm
      [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "Annulé."; exit 0; }
      activate httpchaos scenario-2-rollback-db-incompatibility
      watch_metrics 2 60
      ;;
    3)
      log "Scénario 3 — Anti-flapping (latence réseau oscillante sur student-service)"
      activate networkchaos scenario-3-anti-flapping-latency
      watch_metrics 3 60
      ;;
    4)
      log "Scénario 4 — Saturation CPU (StressChaos sur teacher-admin-service)"
      activate stresschaos scenario-4-cpu-stress
      watch_metrics 4 60
      ;;
    5)
      log "Scénario 5 — Scale-down sous le minimum absolu (enrollment-service)"
      activate networkchaos scenario-5-scale-down-minimum
      watch_metrics 5 60
      ;;
    6)
      log "Scénario 6 — Cascade 2 services (pod-failure total student-service)"
      warn "enrollment-service va perdre sa dépendance student-service → erreurs 502 attendues"
      activate podchaos scenario-6-cascade-2services
      watch_metrics 6 60
      ;;
    7)
      log "Scénario 7 — Cascade DB (latence Postgres → 3 services impactés)"
      warn "Les 3 services vont ralentir simultanément → cause racine = postgres"
      activate networkchaos scenario-7-cascade-db-root-cause
      watch_metrics 7 60
      ;;
    8)
      log "Scénario 8 — Combiné : quorum fragilisé + rollback incompatible"
      warn "Pré-requis scénario 2 requis (v2 déployé + table compatibilité)"
      read -p "  Ces pré-requis sont satisfaits ? (y/N) " confirm
      [[ "${confirm}" == "y" || "${confirm}" == "Y" ]] || { echo "Annulé."; exit 0; }
      activate podchaos  scenario-8a-quorum-fragile
      activate httpchaos scenario-8b-rollback-trigger
      watch_metrics 8 60
      ;;
    *)
      err "Scénario inconnu : ${scenario}. Valeurs valides : 1 à 8"
      ;;
  esac
}

stop_scenario() {
  local scenario=$1
  check_chaos_mesh

  case "${scenario}" in
    1) deactivate podchaos   scenario-1-quorum-violation ;;
    2) deactivate httpchaos  scenario-2-rollback-db-incompatibility ;;
    3) deactivate networkchaos scenario-3-anti-flapping-latency ;;
    4) deactivate stresschaos  scenario-4-cpu-stress ;;
    5) deactivate networkchaos scenario-5-scale-down-minimum ;;
    6) deactivate podchaos   scenario-6-cascade-2services ;;
    7) deactivate networkchaos scenario-7-cascade-db-root-cause ;;
    8)
       deactivate podchaos  scenario-8a-quorum-fragile
       deactivate httpchaos scenario-8b-rollback-trigger
       ;;
    *) err "Scénario inconnu : ${scenario}. Valeurs valides : 1 à 8" ;;
  esac
  ok "Scénario ${scenario} désactivé — le système va se stabiliser dans quelques secondes"
}

stop_all() {
  check_chaos_mesh
  log "Désactivation de tous les scénarios"
  deactivate podchaos    scenario-1-quorum-violation         || true
  deactivate httpchaos   scenario-2-rollback-db-incompatibility || true
  deactivate networkchaos scenario-3-anti-flapping-latency   || true
  deactivate stresschaos  scenario-4-cpu-stress              || true
  deactivate networkchaos scenario-5-scale-down-minimum      || true
  deactivate podchaos    scenario-6-cascade-2services        || true
  deactivate networkchaos scenario-7-cascade-db-root-cause   || true
  deactivate podchaos    scenario-8a-quorum-fragile          || true
  deactivate httpchaos   scenario-8b-rollback-trigger        || true
  ok "Tous les scénarios désactivés"
}

status_all() {
  check_chaos_mesh
  log "État de tous les scénarios"
  echo ""
  printf "%-50s %-15s %-10s\n" "RESSOURCE" "TYPE" "ACTIF"
  printf "%-50s %-15s %-10s\n" "--------" "----" "-----"

  for res in \
    "podchaos/scenario-1-quorum-violation" \
    "httpchaos/scenario-2-rollback-db-incompatibility" \
    "networkchaos/scenario-3-anti-flapping-latency" \
    "stresschaos/scenario-4-cpu-stress" \
    "networkchaos/scenario-5-scale-down-minimum" \
    "podchaos/scenario-6-cascade-2services" \
    "networkchaos/scenario-7-cascade-db-root-cause" \
    "podchaos/scenario-8a-quorum-fragile" \
    "httpchaos/scenario-8b-rollback-trigger"; do
    type="${res%%/*}"
    name="${res##*/}"
    suspended=$(kubectl get "${type}" "${name}" -n "${CHAOS_NS}" \
      -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "absent")
    if [[ "${suspended}" == "false" ]]; then
      active="\033[1;32mOUI\033[0m"
    elif [[ "${suspended}" == "true" ]]; then
      active="non"
    else
      active="\033[1;31mABSENT\033[0m"
    fi
    printf "%-50s %-15s " "${name}" "${type}"
    echo -e "${active}"
  done
  echo ""
}

# ============================================================
# Point d'entrée
# ============================================================
if [[ $# -lt 1 ]]; then
  echo "Usage : ./trigger.sh <start|stop|stop-all|status> [numero_scenario]"
  exit 1
fi

ACTION=$1
SCENARIO=${2:-""}

case "${ACTION}" in
  start)    [[ -z "${SCENARIO}" ]] && err "Précise le numéro du scénario (1-8)"; start_scenario "${SCENARIO}" ;;
  stop)     [[ -z "${SCENARIO}" ]] && err "Précise le numéro du scénario (1-8)"; stop_scenario  "${SCENARIO}" ;;
  stop-all) stop_all ;;
  status)   status_all ;;
  *) err "Action inconnue : ${ACTION}. Valeurs valides : start, stop, stop-all, status" ;;
esac
