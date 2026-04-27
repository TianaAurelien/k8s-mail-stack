#!/bin/bash
set -euo pipefail

# --- CONFIGURATION ---
NS="mail-stack"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}🚀 Lancement de la maintenance intelligente MariaDB...${NC}\n"

# 1. Détection dynamique d'un pod MariaDB prêt
echo -ne "🔍 Recherche d'un nœud MariaDB disponible... "
# On cherche n'importe quel pod du cluster qui est en phase 'Running'
POD_MARIADB=$(kubectl get pods -n "$NS" -l app=mariadb-galera --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' || echo "")

if [[ -z "$POD_MARIADB" ]]; then
    echo -e "${RED}ERREUR : Aucun pod MariaDB n'est en ligne.${NC}"
    exit 1
fi
echo -e "${GREEN}OK ($POD_MARIADB)${NC}"

# Dovecot : nécessaire pour générer les hashes de mots de passe
echo -ne "🔍 Vérification de Dovecot... "
POD_DOVECOT=$(kubectl get pods -n "$NS" -l app=dovecot --field-selector=status.phase=Running -o name | head -n 1 | cut -d'/' -f2 || echo "")

if [[ -z "$POD_DOVECOT" ]]; then
    echo -e "${RED}ERREUR : Aucun pod Dovecot n'est prêt.${NC}"
    exit 1
fi
echo -e "${GREEN}OK ($POD_DOVECOT)${NC}"

# 2. Récupération du mot de passe root
echo -ne "🔑 Récupération du secret SQL... "
TARGET_PASS=$(kubectl get secret mail-secrets -n "$NS" -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 --decode)
SQL_AUTH="-u root -p$TARGET_PASS"
RUN_SQL="kubectl exec -i $POD_MARIADB -n $NS -- mariadb $SQL_AUTH"
echo -e "${GREEN}OK${NC}"

# 3. Vérification/Création des bases de données
echo -e "📦 Vérification des Bases de Données..."
for DB in "mailserver" "roundcube"; do
    $RUN_SQL -e "CREATE DATABASE IF NOT EXISTS $DB;"
    echo -e "  ➡ $DB : ${GREEN}Vérifié${NC}"
done

# 4. Réparation et Structuration des Tables
echo -e "🛠  Réparation des tables et nettoyage..."
$RUN_SQL mailserver <<EOF
SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE IF NOT EXISTS virtual_domains (
  id INT NOT NULL AUTO_INCREMENT,
  name VARCHAR(50) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY (name)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS virtual_users (
  id INT NOT NULL AUTO_INCREMENT,
  domain_id INT NOT NULL,
  password VARCHAR(255) NOT NULL,
  email VARCHAR(120) NOT NULL,
  quota BIGINT NOT NULL,
  enabled TINYINT(1) DEFAULT 1,
  PRIMARY KEY (id),
  UNIQUE KEY email (email),
  FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS virtual_aliases (
  id INT NOT NULL AUTO_INCREMENT,
  domain_id INT NOT NULL,
  source VARCHAR(100) NOT NULL,
  destination VARCHAR(100) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY unique_alias (source, destination),
  FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

SET FOREIGN_KEY_CHECKS = 1;
EOF
echo -e "  ➡ Schémas et Index : ${GREEN}OK${NC}"

# 5. Vérification des privilèges SQL
echo -e "👤 Vérification des accès SQL..."
for USER in "mailuser" "dovecot" "roundcube"; do
    $RUN_SQL <<EOF
CREATE USER IF NOT EXISTS '$USER'@'%' IDENTIFIED BY '$TARGET_PASS';
ALTER USER '$USER'@'%' IDENTIFIED BY '$TARGET_PASS';
GRANT ALL PRIVILEGES ON mailserver.* TO 'mailuser'@'%';
GRANT SELECT ON mailserver.* TO 'dovecot'@'%';
GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'%';
FLUSH PRIVILEGES;
EOF
    echo -e "  ➡ Utilisateur $USER : ${GREEN}Vérifié${NC}"
done

# 6. Synchronisation des Comptes Mails
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
    
    HASH=$(kubectl exec -n "$NS" "$POD_DOVECOT" -- doveadm pw -s SHA512-CRYPT -p "$PASS" | tr -d '\n')
    
    $RUN_SQL mailserver <<EOF
INSERT IGNORE INTO virtual_domains (name) VALUES ('$DOMAIN');
INSERT INTO virtual_users (domain_id, email, password, quota, enabled)
SELECT id, '$EMAIL', '$HASH', $QUOTA_BYTES, 1 FROM virtual_domains WHERE name='$DOMAIN'
ON DUPLICATE KEY UPDATE password='$HASH', quota=$QUOTA_BYTES;
EOF
    echo -e "  ➡ $EMAIL : ${GREEN}OK${NC}"
done

# 7. Synchronisation des Alias
echo -e "🔗 Synchronisation des alias..."
DEFAULT_ALIASES=(
    "postmaster@k8s.malagasy.com admin@k8s.malagasy.com"
    "abuse@k8s.malagasy.com admin@k8s.malagasy.com"
    "hostmaster@k8s.malagasy.com admin@k8s.malagasy.com"
    "sysadmins@k8s.malagasy.com admin@k8s.malagasy.com"
)

for a in "${DEFAULT_ALIASES[@]}"; do
    read -r SOURCE DEST <<< "$a"
    DOMAIN=$(echo "$SOURCE" | cut -d'@' -f2)
    $RUN_SQL mailserver <<EOF
INSERT INTO virtual_aliases (domain_id, source, destination)
SELECT id, '$SOURCE', '$DEST' FROM virtual_domains WHERE name='$DOMAIN'
ON DUPLICATE KEY UPDATE destination='$DEST';
EOF
done

echo -e "\n${BLUE}📊 --- RÉCAPITULATIF FINAL --- ${NC}"
$RUN_SQL mailserver -e "SELECT email, quota/1024/1024/1024 as 'Quota_GB' FROM virtual_users; SELECT source, destination FROM virtual_aliases;"

echo -e "\n${GREEN}✨ Félicitations Aurelien ! La maintenance est terminée.${NC}"
