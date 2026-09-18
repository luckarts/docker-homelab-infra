#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Orchestrateur de l'infrastructure Docker partagée
# =============================================================================
# Usage: ./deploy.sh <sous-commande>
#
# Sous-commandes :
#   networks     Créer les réseaux Docker partagés (idempotent)
#   traefik      Déployer Traefik (à venir)
#   monitoring   Déployer la stack monitoring (à venir)
#   registry     Déployer le registry privé (à venir)
#   watchtower   Déployer Watchtower (à venir)
#   all          Déployer toute l'infra (à venir)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Sous-commande : networks ──────────────────────────────────────────────────
cmd_networks() {
  log_info "Création des réseaux Docker partagés..."

  if docker network ls --format '{{.Name}}' | grep -q '^traefik-web$'; then
    log_warn "Réseau 'traefik-web' existe déjà — ignoré."
  else
    docker network create --driver bridge traefik-web
    log_info "Réseau 'traefik-web' créé."
  fi

  if docker network ls --format '{{.Name}}' | grep -q '^monitoring-network$'; then
    log_warn "Réseau 'monitoring-network' existe déjà — ignoré."
  else
    docker network create --driver bridge monitoring-network
    log_info "Réseau 'monitoring-network' créé."
  fi

  log_info "✓ Réseaux terminé."
}

# ── Sous-commande : placeholders ──────────────────────────────────────────────
cmd_traefik()    { log_warn "traefik : pas encore implémenté."; }
cmd_registry()   { log_warn "registry : pas encore implémenté."; }
cmd_monitoring() { log_warn "monitoring : pas encore implémenté."; }
cmd_watchtower() { log_warn "watchtower : pas encore implémenté."; }
cmd_ci_gate()    { log_warn "ci_gate : pas encore implémenté."; }

cmd_all() {
  cmd_networks
  log_info "Déploiement complet terminé (manque les sous-modules)."
}

cmd_doctor() {
  log_info "Diagnostic de l'infrastructure..."
  echo ""

  echo "Réseaux partagés :"
  for net in traefik-web monitoring-network; do
    if docker network ls --format '{{.Name}}' | grep -q "^$net$"; then
      echo -e "  ${GREEN}✓${NC} $net"
    else
      echo -e "  ${RED}✗${NC} $net"
    fi
  done
}

# ── Aide ──────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
Usage: $(basename "$0") <sous-commande>

Sous-commandes :
  networks     Créer les réseaux Docker partagés (idempotent)
  traefik      Déployer Traefik
  registry     Déployer le registry privé
  monitoring   Déployer la stack monitoring
  watchtower   Déployer Watchtower
  ci_gate      Setup CI gate
  doctor       Vérifier l'état de l'infra
  all          Déployer toute l'infra

Exemple :
  ./scripts/deploy.sh networks
  ./scripts/deploy.sh doctor
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
main() {
  if [[ $# -lt 1 ]]; then
    cmd_help
    exit 1
  fi

  local subcmd="$1"
  shift

  case "$subcmd" in
    networks)    cmd_networks    "$@" ;;
    traefik)     cmd_traefik     "$@" ;;
    registry)    cmd_registry    "$@" ;;
    monitoring)  cmd_monitoring  "$@" ;;
    watchtower)  cmd_watchtower  "$@" ;;
    ci_gate)     cmd_ci_gate     "$@" ;;
    doctor)      cmd_doctor      "$@" ;;
    all)         cmd_all         "$@" ;;
    help|--help|-h) cmd_help     "$@" ;;
    *)
      log_error "Sous-commande inconnue : $subcmd"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"