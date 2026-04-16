#!/bin/bash
# scripts/manage-mail-users.sh
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
NS="mail-stack"

# Récupération dynamique du mot de passe root
echo -ne "🔑 Récupération du secret root... "
ROOT_PASS=$(kubectl get secret mail-secrets -n $NS -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 --decode)
echo -e "${GREEN}OK${NC}"

DEFAULT_USERS=(
    "admin@k8s.malagasy.com k8sadmin 2"
    "harivony@k8s.malagasy.com k8sharivony 1"
    "nanja@k8s.malagasy.com k8snanja 1"
    "smith@k8s.malagasy.com k8ssmith 1"
    "lalaina@k8s.malagasy.com k8slalaina 1"
    "fano@k8s.malagasy.com k8sfano 1"
    "rivo@k8s.malagasy.com k8srivo 1"
    "fitahina@k8s.malagasy.com k8sfitahina 1"
    "aurelien@k8s.malagasy.com k8saurelien 1"
    "contact@k8s.malagasy.com k8scontact 0.5"
    "info@k8s.malagasy.com k8sinfo 0.5"
)

DEFAULT_ALIASES=(
    "postmaster@k8s.malagasy.com admin@k8s.malagasy.com"
    "abuse@k8s.malagasy.com admin@k8s.malagasy.com"
    "hostmaster@k8s.malagasy.com admin@k8s.malagasy.com"
    "sysadmins@k8s.malagasy.com admin@k8s.malagasy.com"
)

add_user() {
    local EMAIL=$1
    local PASS=$2
    local QUOTA_GB=${3:-1}
    local QUOTA_BYTES=$(awk "BEGIN {print int($QUOTA_GB * 1024 * 1024 * 1024)}")
    local DOMAIN=$(echo "$EMAIL" | cut -d'@' -f2)

    echo -ne "➡ Synchronisation de $EMAIL... "

    local POD_MARIADB=$(kubectl get pod -n $NS -l app=mariadb-galera -o jsonpath='{.items[0].metadata.name}')
    local POD_DOVECOT=$(kubectl get pod -n $NS -l app=dovecot -o jsonpath='{.items[0].metadata.name}')

    # 1. Domaine
    kubectl exec -n $NS "$POD_MARIADB" -- mariadb -u root -p"$ROOT_PASS" mailserver -e \
        "INSERT IGNORE INTO virtual_domains (name) VALUES ('$DOMAIN');"

    # 2. Hash
    local HASH=$(kubectl exec -n $NS "$POD_DOVECOT" -- doveadm pw -s SHA512-CRYPT -p "$PASS" | tr -d '\n')

    # 3. ID Domaine
    local DOMAIN_ID=$(kubectl exec -n $NS "$POD_MARIADB" -- mariadb -u root -p"$ROOT_PASS" mailserver -sN -e \
        "SELECT id FROM virtual_domains WHERE name='$DOMAIN' LIMIT 1")

    # 4. Upsert User
    kubectl exec -n $NS "$POD_MARIADB" -- mariadb -u root -p"$ROOT_PASS" mailserver -e "
    INSERT INTO virtual_users (domain_id, email, password, quota, enabled)
    VALUES ($DOMAIN_ID, '$EMAIL', '$HASH', $QUOTA_BYTES, 1)
    ON DUPLICATE KEY UPDATE password='$HASH', quota=$QUOTA_BYTES;"
    
    echo -e "${GREEN}OK${NC}"
}

add_alias() {
    local SOURCE=$1
    local DESTINATION=$2
    local DOMAIN=$(echo "$SOURCE" | cut -d'@' -f2)

    echo -ne "➡ Alias : $SOURCE... "
    local POD_MARIADB=$(kubectl get pod -n $NS -l app=mariadb-galera -o jsonpath='{.items[0].metadata.name}')
    local DOMAIN_ID=$(kubectl exec -n $NS "$POD_MARIADB" -- mariadb -u root -p"$ROOT_PASS" mailserver -sN -e \
        "SELECT id FROM virtual_domains WHERE name='$DOMAIN' LIMIT 1")

    kubectl exec -n $NS "$POD_MARIADB" -- mariadb -u root -p"$ROOT_PASS" mailserver -e "
    INSERT INTO virtual_aliases (domain_id, source, destination)
    VALUES ($DOMAIN_ID, '$SOURCE', '$DESTINATION')
    ON DUPLICATE KEY UPDATE destination='$DESTINATION';"
    echo -e "${GREEN}OK${NC}"
}

# Exécution
if [ $# -ge 2 ]; then
    add_user "$1" "$2" "${3:-1}"
else
    for u in "${DEFAULT_USERS[@]}"; do add_user $u; done
    for a in "${DEFAULT_ALIASES[@]}"; do add_alias $a; done
fi
