#!/usr/bin/env bash
# Setup CrowdSec intrusion detection + firewall bouncer natif
#
# crowdsec (detection) tourne en container ; cs-firewall-bouncer
# (bannissement iptables/nftables) tourne en paquet natif sur l'hote —
# CrowdSec ne publie pas d'image Docker officielle pour ce bouncer, car
# il doit manipuler le pare-feu de l'hote directement.
#
# Usage:
#   sudo ./scripts/setup-crowdsec.sh
#
# Pre-requis:
#   - monitoring/.env.monitoring rempli
#   - ./scripts/deploy.sh monitoring deja lance une premiere fois
#
# Ce script est IDEMPOTENT — on peut le relancer sans risque.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ce script installe un paquet systeme — lance-le avec sudo." >&2
  exit 1
fi

echo "Demarrage du container CrowdSec (detection)..."
docker compose -f monitoring/compose.monitoring.yml --env-file monitoring/.env.monitoring up -d crowdsec

echo "Attente de l'initialisation de CrowdSec..."
sleep 10

echo "Metriques CrowdSec :"
docker compose -f monitoring/compose.monitoring.yml exec crowdsec cscli metrics

echo ""
echo "Generation de la cle API pour le bouncer natif..."
BOUNCER_KEY="$(docker compose -f monitoring/compose.monitoring.yml exec -T crowdsec \
  cscli bouncers add firewall-bouncer -o raw || true)"

if [ -z "$BOUNCER_KEY" ]; then
  echo "Cle deja existante ou erreur — verification..."
  docker compose -f monitoring/compose.monitoring.yml exec crowdsec cscli bouncers list
  echo ""
  echo "Si le bouncer existe deja :"
  echo "  docker compose -f monitoring/compose.monitoring.yml exec crowdsec cscli bouncers delete firewall-bouncer"
  echo "puis relancer ce script."
  exit 1
fi

echo "Installation du paquet cs-firewall-bouncer (depot officiel CrowdSec)..."
if ! command -v cs-firewall-bouncer >/dev/null 2>&1; then
  curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
  apt-get install -y crowdsec-firewall-bouncer-iptables
fi

echo "Configuration du bouncer natif (LAPI via 127.0.0.1:8080)..."
CONF=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
sed -i "s#^api_url:.*#api_url: http://127.0.0.1:8080/#" "$CONF"
sed -i "s#^api_key:.*#api_key: ${BOUNCER_KEY}#" "$CONF"

systemctl restart crowdsec-firewall-bouncer
systemctl enable crowdsec-firewall-bouncer

echo ""
echo "Verification :"
docker compose -f monitoring/compose.monitoring.yml exec crowdsec cscli bouncers list
systemctl status crowdsec-firewall-bouncer --no-pager -l | head -10

echo ""
echo "CrowdSec deploye (detection en container + bouncer natif systemd)."
echo " - SSH bruteforce  -> ban 4h"
echo " - HTTP scan       -> ban 1h"
echo " - Bad user-agent  -> ban 2h"
echo ""
echo "Metriques CrowdSec dans Grafana via le datasource Prometheus."
