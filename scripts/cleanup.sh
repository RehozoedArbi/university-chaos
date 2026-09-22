#!/bin/bash
set -euo pipefail

log() { echo -e "\n\033[1;34m[cleanup]\033[0m $1"; }
ok()  { echo -e "\033[1;32m  ✓ $1\033[0m"; }

log "1. Suppression de university-chaos"
helm uninstall university-chaos -n university-chaos 2>/dev/null || true
kubectl delete namespace university-chaos --ignore-not-found=true
ok "university-chaos supprimé"

log "2. Suppression de Chaos Mesh"
helm uninstall chaos-mesh -n chaos-mesh 2>/dev/null || true
kubectl delete namespace chaos-mesh --ignore-not-found=true
ok "Chaos Mesh supprimé"

ok "Nettoyage terminé avec succès !"