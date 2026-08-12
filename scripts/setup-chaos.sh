#!/bin/bash
set -euo pipefail

# ============================================================
# setup-chaos.sh — Installe Chaos Mesh via Helm et déploie
# le chart university-chaos (scénarios désactivés par défaut).
# ============================================================

CHAOS_MESH_VERSION="2.7.0"
CHAOS_NS="chaos-mesh"
CHART_PATH="$(cd "$(dirname "$0")/.." && pwd)/university-chaos"

log() { echo -e "\n\033[1;34m[setup-chaos]\033[0m $1"; }
ok()  { echo -e "\033[1;32m  ✓ $1\033[0m"; }
err() { echo -e "\033[1;31m  ✗ $1\033[0m"; exit 1; }

log "1. Vérification des prérequis"
for cmd in helm kubectl; do
  command -v "$cmd" &>/dev/null || err "$cmd non trouvé"
done
ok "helm et kubectl présents"

log "2. Ajout du repo Helm Chaos Mesh"
helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
helm repo update
ok "Repo Chaos Mesh à jour"

log "3. Installation de Chaos Mesh (namespace: ${CHAOS_NS})"
if helm list -n "${CHAOS_NS}" | grep -q chaos-mesh; then
  ok "Chaos Mesh déjà installé — mise à jour"
  helm upgrade chaos-mesh chaos-mesh/chaos-mesh \
    --namespace "${CHAOS_NS}" \
    --version "${CHAOS_MESH_VERSION}" \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock \
    --wait
else
  helm install chaos-mesh chaos-mesh/chaos-mesh \
    --namespace "${CHAOS_NS}" \
    --create-namespace \
    --version "${CHAOS_MESH_VERSION}" \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock \
    --wait
fi
ok "Chaos Mesh installé (version ${CHAOS_MESH_VERSION})"

log "4. Attente que Chaos Mesh soit opérationnel"
kubectl wait --for=condition=Ready pods \
  -l app.kubernetes.io/instance=chaos-mesh \
  -n "${CHAOS_NS}" \
  --timeout=120s
ok "Chaos Mesh opérationnel"

log "5. Déploiement du chart university-chaos (scénarios désactivés par défaut)"
helm upgrade --install university-chaos "${CHART_PATH}" \
  --namespace university-chaos \
  --create-namespace \
  --wait
ok "Chart university-chaos déployé"

log "6. Vérification des ressources Chaos Mesh créées"
echo ""
kubectl get podchaos,networkchaos,httpchaos,stresschaos \
  -n university-chaos 2>/dev/null || echo "  (aucune ressource active)"

echo ""
ok "Setup chaos engineering terminé"
echo ""
echo "  Pour déclencher un scénario :"
echo "    ./scripts/trigger.sh start <1-8>"
echo ""
echo "  Pour voir l'état de tous les scénarios :"
echo "    ./scripts/trigger.sh status"
echo ""
