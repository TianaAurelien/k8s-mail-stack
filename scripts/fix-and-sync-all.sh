#!/bin/bash
# scripts/fix-and-sync-all.sh
set -euo pipefail

# --- CONFIGURATION ---
NS="mail-stack"
ROUNDCUBE_SQL="database/roundcube_init.sql"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}🚀 Démarrage de l'initialisation intelligente et forcée de MariaDB...${NC}\n"

# 1. Récupération du mot de passe cible depuis le secret k8s
echo -ne "🔑 Récupération du secret de la stack... "
TARGET_PASS=$(kubectl get secret mail-secrets -n "$NS" -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 --decode)
if [ -z "$TARGET_PASS" ]; then
    echo -e "${RED}Erreur : Impossible de lire MYSQL_ROOT_PASSWORD dans le secret mail-secrets.${NC}"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# 2. Identification des Pods
POD_MARIADB="mariadb-galera-0"
POD_DOVECOT=$(kubectl get pods -n "$NS" -l app=dovecot -o jsonpath='{.items[0].metadata.name}' || echo "")

if [ -z "$POD_DOVECOT" ]; then
    echo -e "${RED}❌ Erreur : Aucun Pod Dovecot trouvé. Indispensable pour hasher les mots de passe.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Pods identifiés :${NC} MariaDB ($POD_MARIADB), Dovecot ($POD_DOVECOT)"

# 3. Test de connexion intelligent pour éviter "Access Denied"
echo -ne "🔍 Test d'accès MariaDB... "
if kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb -u root -e "SELECT 1" >/dev/null 2>&1; then
    SQL_AUTH="-u root"
    echo -e "${GREEN}Accès root libre détecté.${NC}"
elif kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb -u root -p"$TARGET_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    SQL_AUTH="-u root -p$TARGET_PASS"
    echo -e "${YELLOW}Accès déjà sécurisé détecté.${NC}"
else
    echo -e "${RED}ERREUR : Accès refusé (Vérifie le mot de passe root).${NC}"
    exit 1
fi

# 4. Vérification et Forçage des Bases de Données (Foundation)
echo -e "📦 Vérification des bases de données..."
for DB in "mailserver" "roundcube"; do
    DB_EXISTS=$(kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH -N -e "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$DB';")
    if [ "$DB_EXISTS" -eq 0 ]; then
        echo -e "  ➡ Base [$DB] : ${RED}Manquante${NC}. Forçage de la création..."
        kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH -e "CREATE DATABASE IF NOT EXISTS $DB;"
    else
        echo -e "  ➡ Base [$DB] : ${GREEN}OK${NC}"
    fi
done

# 5. Forçage du Schéma (Si MariaDB a sauté l'init auto)
echo -e "📧 Vérification des tables mailserver..."
TABLE_COUNT=$(kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH mailserver -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='mailserver';")

if [ "$TABLE_COUNT" -lt 3 ]; then
    echo -e "  ⚠️  Schéma incomplet ($TABLE_COUNT tables). Injection manuelle depuis le ConfigMap..."
    SQL_SCHEMA=$(kubectl get configmap mariadb-init-scripts -n "$NS" -o jsonpath='{.data.01-init-mailserver\.sql}' 2>/dev/null || echo "")
    if [ -z "$SQL_SCHEMA" ]; then
        # On essaie le fallback sur foundation si mailserver n'est pas séparé
        SQL_SCHEMA=$(kubectl get configmap mariadb-init-scripts -n "$NS" -o jsonpath='{.data.01-init-foundation\.sql}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$SQL_SCHEMA" ]; then
        kubectl exec -i "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH mailserver <<EOF
$SQL_SCHEMA
EOF
        echo -e "  ${GREEN}✅ Tables injectées avec succès.${NC}"
    else
        echo -e "  ${RED}❌ Erreur : Impossible de trouver le schéma SQL dans le ConfigMap.${NC}"
    fi
else
    echo -e "  ${GREEN}✅ Schéma déjà présent.${NC}"
fi

# 6. Vérification/Création des Utilisateurs Applicatifs
echo -e "👤 Vérification des utilisateurs SQL techniques..."
APP_USERS=("mailuser" "dovecot" "roundcube")
for USER in "${APP_USERS[@]}"; do
    USER_EXISTS=$(kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH -N -e "SELECT COUNT(*) FROM mysql.user WHERE User = '$USER';")
    if [ "$USER_EXISTS" -eq 0 ]; then
        echo -e "  ➡ Utilisateur [$USER] : ${YELLOW}Création...${NC}"
        kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH <<EOF
CREATE USER IF NOT EXISTS '$USER'@'%' IDENTIFIED BY '$TARGET_PASS';
GRANT ALL PRIVILEGES ON mailserver.* TO 'mailuser'@'%';
GRANT SELECT ON mailserver.* TO 'dovecot'@'%';
GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'%';
FLUSH PRIVILEGES;
EOF
    else
        echo -e "  ➡ Utilisateur [$USER] : ${GREEN}OK${NC}"
        # On force la mise à jour du password au cas où
        kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH -e "ALTER USER '$USER'@'%' IDENTIFIED BY '$TARGET_PASS'; FLUSH PRIVILEGES;"
    fi
done

# 7. Initialisation ROUNDCUBE (Fichier local)
if [ -f "$ROUNDCUBE_SQL" ]; then
    echo -e "🌐 Vérification Roundcube (Fichier local)..."
    RC_TABLE_COUNT=$(kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH roundcube -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='roundcube';")
    if [ "$RC_TABLE_COUNT" -lt 5 ]; then
        echo -e "  ⚠️  Roundcube vide. Injection du fichier local..."
        kubectl exec -i "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH roundcube < "$ROUNDCUBE_SQL"
    fi
fi

# 8. Synchronisation des Comptes Mails et Alias
echo -e "👥 Synchronisation des comptes mails (Dovecot Hash)..."

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

for u in "${DEFAULT_USERS[@]}"; do
    read -r EMAIL PASS QUOTA_GB <<< "$u"
    DOMAIN=$(echo "$EMAIL" | cut -d'@' -f2)
    QUOTA_BYTES=$(awk "BEGIN {print int($QUOTA_GB * 1024 * 1024 * 1024)}")
    
    # Vérification si l'utilisateur existe déjà
    EXISTS=$(kubectl exec "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH mailserver -N -e "SELECT COUNT(*) FROM virtual_users WHERE email='$EMAIL';")
    
    if [ "$EXISTS" -eq 0 ]; then
        echo -ne "  ➡ Ajout : $EMAIL... "
        HASH=$(kubectl exec -n "$NS" "$POD_DOVECOT" -- doveadm pw -s SHA512-CRYPT -p "$PASS" | tr -d '\n')
        kubectl exec -i "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH mailserver <<EOF
INSERT IGNORE INTO virtual_domains (name) VALUES ('$DOMAIN');
INSERT INTO virtual_users (domain_id, email, password, quota, enabled)
SELECT id, '$EMAIL', '$HASH', $QUOTA_BYTES, 1 FROM virtual_domains WHERE name='$DOMAIN';
EOF
        echo -e "${GREEN}Ajouté${NC}"
    else
        echo -e "  ➡ $EMAIL : ${GREEN}OK (Déjà présent)${NC}"
    fi
done

# 9. SÉCURISATION ROOT FINALE (Unifie l'accès)
echo -e "🔒 Sécurisation finale du compte root..."
kubectl exec -i "$POD_MARIADB" -n "$NS" -- mariadb $SQL_AUTH <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$TARGET_PASS';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '$TARGET_PASS';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$TARGET_PASS';
ALTER USER 'root'@'%' IDENTIFIED BY '$TARGET_PASS';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

echo -e "\n${GREEN}✨ Félicitations Aurelien ! MariaDB est totalement synchronisée et sécurisée.${NC}"
