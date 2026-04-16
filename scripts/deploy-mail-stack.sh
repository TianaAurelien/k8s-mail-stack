#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NS="mail-stack"

echo -e "${GREEN}🚀 DÉPLOIEMENT DE LA STACK MAIL (K8S HA)${NC}"
echo "===================================================================="

# --- ÉTAPE 1 : INFRASTRUCTURE ---
echo -e "${YELLOW}[1/8] Infrastructure de base...${NC}"
kubectl apply -f base/mail-config.yaml -n ${NS}
kubectl apply -f base/mail-storage-complete.yaml -n ${NS}

# --- ÉTAPE 2 : SÉCURITÉ ---
echo -e "${GREEN}[2/8] Sécurité (Spam/Antivirus)...${NC}"
kubectl apply -f security/unbound.yaml -n ${NS}
# CORRECTION : Chemin mis à jour vers le sous-dossier clamav/
kubectl apply -f security/clamav/clamav.yaml -n ${NS}
kubectl apply -f security/rspamd-config.yaml -n ${NS}
kubectl apply -f security/rspamd.yaml -n ${NS}

# --- ÉTAPE 3 : BDD ---
echo -e "${GREEN}[3/8] MariaDB Galera & Redis...${NC}"
kubectl apply -f database/mariadb-init-configmap.yaml -n ${NS}
kubectl apply -f database/mariadb-galera-config.yaml -n ${NS}
kubectl apply -f database/mariadb-deployment.yaml -n ${NS}
kubectl apply -f database/mariadb-services.yaml -n ${NS}
kubectl apply -f database/redis-deployment.yaml -n ${NS}

echo -e "${YELLOW}⏳ Attente de MariaDB...${NC}"
kubectl wait --for=condition=ready pod/mariadb-galera-0 -n ${NS} --timeout=300s

# --- ÉTAPE 4 : INITIALISATION SQL (FORCÉE) ---
echo -e "${GREEN}[4/8] Configuration des schémas SQL...${NC}"

ROOT_PASS=$(kubectl get secret mail-secrets -n "${NS}" -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 --decode)

# Injection du schéma mailserver (on ignore si déjà présent)
echo -e "${YELLOW}Injection du schéma mailserver...${NC}"
kubectl exec -i mariadb-galera-0 -n "${NS}" -- mariadb -u root --password="${ROOT_PASS}" -e "$(kubectl get configmap mariadb-init-scripts -n ${NS} -o jsonpath='{.data.01-init-mailserver\.sql}')" 2>/dev/null || echo "Schéma mailserver déjà présent."

if [ -f "database/roundcube_init.sql" ]; then
    echo -e "${YELLOW}Importation Roundcube...${NC}"
    kubectl exec -i mariadb-galera-0 -n "${NS}" -- mariadb -u root --password="${ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS roundcube;"
    # CORRECTION : Ajout de || true pour ne pas bloquer si les tables existent
    kubectl exec -i mariadb-galera-0 -n "${NS}" -- mariadb -u root --password="${ROOT_PASS}" roundcube < database/roundcube_init.sql 2>/dev/null || echo "Tables Roundcube déjà présentes."
fi

# --- ÉTAPE 5 : SERVEUR MAIL ---
echo -e "${GREEN}[5/8] Postfix et Dovecot...${NC}"
kubectl apply -f mail/postfix-config.yaml -n ${NS}
kubectl apply -f mail/postfix-deployment.yaml -n ${NS}
kubectl apply -f mail/dovecot-configmap.yaml -n ${NS}
kubectl apply -f mail/dovecot.yaml -n ${NS}

# --- ÉTAPE 6 : WEBMAIL ---
echo -e "${GREEN}[6/8] Roundcube...${NC}"
kubectl apply -f mail/roundcube-configmap.yaml -n ${NS}
kubectl apply -f mail/roundcube.yaml -n ${NS}

# --- ÉTAPE 8 : UTILISATEURS ---
echo -e "${YELLOW}[8/8] Sync comptes...${NC}"
kubectl wait --for=condition=ready pod -l app=dovecot -n "${NS}" --timeout=300s
bash scripts/manage-mail-users.sh

echo "===================================================================="
echo -e "${GREEN}✨ DÉPLOIEMENT TERMINÉ !${NC}"
