#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

cd "$(dirname "$0")/.."
BASE_DIR="k8s"
NS="mail-stack"

echo -e "${GREEN}🚀 DÉPLOIEMENT DE LA STACK MAIL (K8S HA)${NC}"
echo "===================================================================="

# --- ÉTAPE 1 : INFRASTRUCTURE ---
echo -e "${YELLOW}[1/8] Infrastructure de base...${NC}"
kubectl apply -f ${BASE_DIR}/base/mail-config.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/base/mail-storage-complete.yaml -n ${NS}

# --- ÉTAPE 2 : SÉCURITÉ ---
echo -e "${GREEN}[2/8] Sécurité (Spam/Antivirus/DNS)...${NC}"
kubectl apply -f ${BASE_DIR}/security/unbound/unbound.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/security/clamav/clamav.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/security/rspamd/rspamd-config.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/security/rspamd/rspamd-settings-configmap.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/security/rspamd/rspamd.yaml -n ${NS}

# --- ÉTAPE 3 : BDD ---
echo -e "${GREEN}[3/8] MariaDB Galera & Redis...${NC}"
kubectl apply -f ${BASE_DIR}/database/mariadb-init-configmap.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/database/mariadb-galera-config.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/database/mariadb-deployment.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/database/mariadb-services.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/database/redis-deployment.yaml -n ${NS}

echo -e "${YELLOW}⏳ Attente de MariaDB...${NC}"
kubectl wait --for=condition=ready pod/mariadb-galera-0 -n ${NS} --timeout=300s

# --- ÉTAPE 4 : SERVEUR MAIL (DOIT ÊTRE AVANT LE FIX-SYNC) ---
echo -e "${GREEN}[4/8] Postfix et Dovecot...${NC}"
kubectl apply -f ${BASE_DIR}/mail/postfix/postfix-config.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/mail/postfix/postfix-deployment.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/mail/dovecot/dovecot-configmap.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/mail/dovecot/dovecot.yaml -n ${NS}

# --- ÉTAPE 5 : WEBMAIL ---
echo -e "${GREEN}[5/8] Roundcube...${NC}"
kubectl apply -f ${BASE_DIR}/mail/roundcube/roundcube-configmap.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/mail/roundcube/roundcube.yaml -n ${NS}
kubectl apply -f ${BASE_DIR}/mail/roundcube/roundcube-ingress.yaml -n ${NS}

# --- ÉTAPE 6 : ATTENTE DISPONIBILITÉ ---
echo -e "${YELLOW}[6/8] Attente de la disponibilité des services...${NC}"
kubectl wait --for=condition=ready pod -l app=dovecot -n "${NS}" --timeout=300s

# --- ÉTAPE 7 : MAINTENANCE ET SYNC (LE BON MOMENT) ---
echo -e "${GREEN}[7/8] Injection SQL et Sync des comptes...${NC}"
# On utilise maintenant ton script intelligent qui répare les tables et crée les users
bash scripts/fix-and-sync-all.sh

echo "===================================================================="
echo -e "${GREEN}✨ DÉPLOIEMENT ET CONFIGURATION TERMINÉS !${NC}"
