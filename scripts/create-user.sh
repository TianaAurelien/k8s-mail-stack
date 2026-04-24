#!/bin/bash
# scripts/create-user.sh
set -euo pipefail

# --- CONFIGURATION ---
NS="mail-stack"
DOMAIN="k8s.malagasy.com"

# Couleurs pour le terminal
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Vérification des arguments
if [ "$#" -lt 2 ]; then
    echo -e "Usage: $0 <username> <password> [quota_gb]"
    echo -e "Exemple: $0 giovanni k8sjojo 2"
    exit 1
fi

USER_NAME=$1
USER_PASS=$2
QUOTA_GB=${3:-1} # 1 Go par défaut si non spécifié
EMAIL="${USER_NAME}@${DOMAIN}"
QUOTA_BYTES=$(awk "BEGIN {print int($QUOTA_GB * 1024 * 1024 * 1024)}")

echo -e "${BLUE}🚀 Préparation de l'utilisateur : $EMAIL...${NC}"

# 1. Récupération dynamique des composants
echo -ne "🔑 Récupération du secret SQL... "
ROOT_PASS=$(kubectl get secret mail-secrets -n $NS -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 --decode)
echo -e "${GREEN}OK${NC}"

POD_MARIADB=$(kubectl get pod -n $NS -l app=mariadb-galera -o jsonpath='{.items[0].metadata.name}')
POD_DOVECOT=$(kubectl get pod -n $NS -l app=dovecot -o jsonpath='{.items[0].metadata.name}')

# 2. Génération du Hash sécurisé via Dovecot
echo -ne "🔐 Génération du hash SHA512-CRYPT... "
HASH=$(kubectl exec -n $NS "$POD_DOVECOT" -- doveadm pw -s SHA512-CRYPT -p "$USER_PASS" | tr -d '\n')
echo -e "${GREEN}OK${NC}"

# 3. Insertion SQL sécurisée
echo -ne "💾 Enregistrement dans MariaDB... "
kubectl exec -i "$POD_MARIADB" -n "$NS" -- mariadb -u root -p"$ROOT_PASS" mailserver <<EOF
-- 1. Assurer que le domaine existe
INSERT IGNORE INTO virtual_domains (name) VALUES ('$DOMAIN');

-- 2. Insérer ou mettre à jour l'utilisateur (Upsert)
INSERT INTO virtual_users (domain_id, email, password, quota, enabled)
SELECT id, '$EMAIL', '$HASH', $QUOTA_BYTES, 1 FROM virtual_domains WHERE name='$DOMAIN'
ON DUPLICATE KEY UPDATE password='$HASH', quota=$QUOTA_BYTES;
EOF
echo -e "${GREEN}OK${NC}"

echo -e "\n${GREEN}✨ Félicitations ! L'utilisateur $EMAIL est prêt.${NC}"
echo -e "Identifiant : ${BLUE}$EMAIL${NC}"
echo -e "Mot de passe : ${BLUE}$USER_PASS${NC}"
