#!/bin/bash
set -euo pipefail

# ============================================================
# trigger.sh — Active ou désactive un scénario de chaos engineering
# Stratégie : kubectl apply pour activer, kubectl delete pour désactiver
# (le champ suspend n'est pas supporté dans Chaos Mesh 2.7)
#
# Usage :
#   ./trigger.sh start <numero>    # active le scénario (crée la ressource)
#   ./trigger.sh stop <numero>     # désactive le scénario (supprime la ressource)
#   ./trigger.sh stop-all          # désactive TOUS les scénarios
#   ./trigger.sh status            # affiche l'état de tous les scénarios
# ============================================================

CHAOS_NS="university-chaos"
APP_NS="university-app"
# Chemin vers les manifests du chart — adapte si ton repo est structuré différemment
CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)/manifests"

log()  { echo -e "\n\033[1;34m[chaos]\033[0m $1"; }
ok()   { echo -e "\033[1;32m  ✓ $1\033[0m"; }
err()  { echo -e "\033[1;31m  ✗ $1\033[0m"; exit 1; }
warn() { echo -e "\033[1;33m  ⚠ $1\033[0m"; }

check_chaos_mesh() {
  kubectl get crd podchaos.chaos-mesh.org &>/dev/null || \
    err "Chaos Mesh non installé. Lance d'abord ./setup-chaos.sh"
}

apply_manifest() {
  local file=$1
  kubectl apply -f "${file}" && ok "Appliqué : ${file##*/}"
}

delete_resource() {
  local kind=$1 name=$2
  if kubectl get "${kind}" "${name}" -n "${CHAOS_NS}" &>/dev/null; then
    kubectl delete "${kind}" "${name}" -n "${CHAOS_NS}"
    ok "${kind}/${name} supprimé"
  else
    ok "${kind}/${name} déjà absent"
  fi
}

watch_pods() {
  local duration=${1:-60}
  log "Observation en cours (${duration}s) — Ctrl+C pour arrêter"
  echo "  → Grafana : http://grafana.university.local:8080"
  echo ""
  for i in $(seq 1 "${duration}"); do
    printf "\r  [%02ds/%02ds] " "$i" "$duration"
    kubectl get pods -n "${APP_NS}" --no-headers \
      -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready' \
      2>/dev/null | paste -sd '|' -
    sleep 1
  done
  echo ""
}

start_scenario() {
  local s=$1
  check_chaos_mesh
  case "${s}" in
    1)
      log "Scénario 1 — Violation du quorum (kill 1 pod enrollment-service)"
      apply_manifest "${CHART_DIR}/scenario-1-quorum/podchaos.yaml"
      watch_pods 60
      ;;
    2)
      log "Scénario 2 — Rollback incompatible avec schéma DB"
      warn "Pré-requis : enrollment-service v2 déployé + migration Alembic + table compatibilité à jour"
      read -r -p "  Ces pré-requis sont satisfaits ? (y/N) " confirm
      [[ "${confirm}" =~ ^[yY]$ ]] || { echo "Annulé."; exit 0; }
      apply_manifest "${CHART_DIR}/scenario-2-rollback-db/httpchaos.yaml"
      watch_pods 60
      ;;
    3)
      log "Scénario 3 — Anti-flapping (latence réseau oscillante sur student-service)"
      apply_manifest "${CHART_DIR}/scenario-3-anti-flapping/networkchaos.yaml"
      watch_pods 60
      ;;
    4)
      log "Scénario 4 — Saturation CPU (teacher-admin-service)"
      apply_manifest "${CHART_DIR}/scenario-4-cpu-stress/stresschaos.yaml"
      watch_pods 60
      ;;
    5)
      log "Scénario 5 — Scale-down sous le minimum absolu (enrollment-service)"
      apply_manifest "${CHART_DIR}/scenario-5-scale-down/networkchaos.yaml"
      watch_pods 60
      ;;
    6)
      log "Scénario 6 — Cascade 2 services (pod-failure total student-service)"
      warn "enrollment-service va perdre sa dépendance → erreurs 502 attendues"
      apply_manifest "${CHART_DIR}/scenario-6-cascade-2services/podchaos.yaml"
      watch_pods 60
      ;;
    7)
      log "Scénario 7 — Cascade DB (latence Postgres → 3 services impactés)"
      warn "Les 3 services vont ralentir → cause racine = postgres"
      apply_manifest "${CHART_DIR}/scenario-7-cascade-db/networkchaos.yaml"
      watch_pods 60
      ;;
    8)
      log "Scénario 8 — Combiné : quorum fragilisé + rollback incompatible"
      warn "Pré-requis scénario 2 requis (v2 + table compatibilité)"
      read -r -p "  Ces pré-requis sont satisfaits ? (y/N) " confirm
      [[ "${confirm}" =~ ^[yY]$ ]] || { echo "Annulé."; exit 0; }
      # Les deux parties sont dans le même fichier (séparées par ---)
      apply_manifest "${CHART_DIR}/scenario-8-combined/chaos.yaml"
      watch_pods 60
      ;;
    *) err "Scénario inconnu : ${s}. Valeurs valides : 1 à 8" ;;
  esac
}

stop_scenario() {
  local s=$1
  check_chaos_mesh
  case "${s}" in
    1) delete_resource podchaos    scenario-1-quorum-violation ;;
    2) delete_resource httpchaos   scenario-2-rollback-db-incompatibility ;;
    3) delete_resource networkchaos scenario-3-anti-flapping-latency ;;
    4) delete_resource stresschaos  scenario-4-cpu-stress ;;
    5) delete_resource networkchaos scenario-5-scale-down-minimum ;;
    6) delete_resource podchaos    scenario-6-cascade-2services ;;
    7) delete_resource networkchaos scenario-7-cascade-db-root-cause ;;
    8)
       delete_resource podchaos  scenario-8a-quorum-fragile
       delete_resource httpchaos scenario-8b-rollback-trigger
       ;;
    *) err "Scénario inconnu : ${s}. Valeurs valides : 1 à 8" ;;
  esac
  ok "Scénario ${s} arrêté — le système va se stabiliser dans quelques secondes"
}

stop_all() {
  check_chaos_mesh
  log "Arrêt de tous les scénarios actifs"
  delete_resource podchaos    scenario-1-quorum-violation          || true
  delete_resource httpchaos   scenario-2-rollback-db-incompatibility || true
  delete_resource networkchaos scenario-3-anti-flapping-latency    || true
  delete_resource stresschaos  scenario-4-cpu-stress               || true
  delete_resource networkchaos scenario-5-scale-down-minimum       || true
  delete_resource podchaos    scenario-6-cascade-2services         || true
  delete_resource networkchaos scenario-7-cascade-db-root-cause    || true
  delete_resource podchaos    scenario-8a-quorum-fragile           || true
  delete_resource httpchaos   scenario-8b-rollback-trigger         || true
  ok "Tous les scénarios arrêtés"
}

status_all() {
  check_chaos_mesh
  log "État de tous les scénarios"
  echo ""
  printf "%-50s %-15s %-10s\n" "RESSOURCE" "TYPE" "ACTIF"
  printf "%-50s %-15s %-10s\n" "--------" "----" "-----"

  check_resource() {
    local kind=$1 name=$2
    if kubectl get "${kind}" "${name}" -n "${CHAOS_NS}" &>/dev/null; then
      echo -e "\033[1;32mOUI\033[0m"
    else
      echo "non"
    fi
  }

  printf "%-50s %-15s " "scenario-1-quorum-violation"             "podchaos";     check_resource podchaos    scenario-1-quorum-violation
  printf "%-50s %-15s " "scenario-2-rollback-db-incompatibility"  "httpchaos";    check_resource httpchaos   scenario-2-rollback-db-incompatibility
  printf "%-50s %-15s " "scenario-3-anti-flapping-latency"        "networkchaos"; check_resource networkchaos scenario-3-anti-flapping-latency
  printf "%-50s %-15s " "scenario-4-cpu-stress"                   "stresschaos";  check_resource stresschaos  scenario-4-cpu-stress
  printf "%-50s %-15s " "scenario-5-scale-down-minimum"           "networkchaos"; check_resource networkchaos scenario-5-scale-down-minimum
  printf "%-50s %-15s " "scenario-6-cascade-2services"            "podchaos";     check_resource podchaos    scenario-6-cascade-2services
  printf "%-50s %-15s " "scenario-7-cascade-db-root-cause"        "networkchaos"; check_resource networkchaos scenario-7-cascade-db-root-cause
  printf "%-50s %-15s " "scenario-8a-quorum-fragile"              "podchaos";     check_resource podchaos    scenario-8a-quorum-fragile
  printf "%-50s %-15s " "scenario-8b-rollback-trigger"            "httpchaos";    check_resource httpchaos   scenario-8b-rollback-trigger
  echo ""
}

# Point d'entrée
[[ $# -lt 1 ]] && { echo "Usage : ./trigger.sh <start|stop|stop-all|status> [numero]"; exit 1; }

ACTION=$1
SCENARIO=${2:-""}

case "${ACTION}" in
  start)    [[ -z "${SCENARIO}" ]] && err "Précise le numéro (1-8)"; start_scenario "${SCENARIO}" ;;
  stop)     [[ -z "${SCENARIO}" ]] && err "Précise le numéro (1-8)"; stop_scenario  "${SCENARIO}" ;;
  stop-all) stop_all ;;
  status)   status_all ;;
  *) err "Action inconnue : ${ACTION}. Valeurs : start, stop, stop-all, status" ;;
esac
