#!/usr/bin/env bash
# Setup Alertmanager with email notifications via Brevo
#
# Usage:
#   ./scripts/setup-alertmanager.sh
#
# Pre-requis:
#   - monitoring/.env.monitoring rempli (ALERTMANAGER_SMTP_USERNAME/PASSWORD)
#   - ./scripts/deploy.sh monitoring deja lance
#
# Ce script est IDEMPOTENT — on peut le relancer sans risque.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "Demarrage d'Alertmanager..."
docker compose -f monitoring/compose.monitoring.yml --env-file monitoring/.env.monitoring up -d alertmanager

echo "Rechargement de Prometheus (prise en compte des nouvelles regles d'alertes)..."
docker compose -f monitoring/compose.monitoring.yml exec prometheus kill -HUP 1 2>/dev/null || \
  docker compose -f monitoring/compose.monitoring.yml restart prometheus

echo "Attente du demarrage d'Alertmanager..."
sleep 5

echo "Verification du statut Alertmanager :"
curl -s http://localhost:9093/api/v2/status | python3 -m json.tool 2>/dev/null || \
  echo "Alertmanager pas encore accessible — verifie 'docker compose logs alertmanager'"

echo ""
echo "Alertmanager deploye."
echo "Alertes envoyees a luc.bachelerieart@gmail.com via Brevo SMTP."
