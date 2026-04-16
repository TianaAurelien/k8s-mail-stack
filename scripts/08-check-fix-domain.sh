#!/bin/bash
# Vérification et correction domaine dans la base de données
# k8smalagasy.com → k8s.malagasy.com (si nécessaire)

set -e

echo "🔍 Vérification domaine dans MariaDB..."

# Attendre que MariaDB soit prêt
echo "⏳ Attente MariaDB..."
kubectl wait --for=condition=ready pod -l app=mariadb-galera -n mail-stack --timeout=60s 2>/dev/null || \
kubectl wait --for=condition=ready pod -l app=mariadb -n mail-stack --timeout=60s || {
    echo "❌ MariaDB non accessible"
    exit 1
}

# Choisir le bon pod MariaDB
if kubectl get pod mariadb-galera-0 -n mail-stack &>/dev/null; then
    MARIADB_POD="mariadb-galera-0"
elif kubectl get pod mariadb-0 -n mail-stack &>/dev/null; then
    MARIADB_POD="mariadb-0"
else
    echo "❌ Aucun pod MariaDB trouvé"
    exit 1
fi

echo "✅ Utilisation pod: $MARIADB_POD"
echo ""

# Fonction pour exécuter SQL
exec_sql() {
    kubectl exec $MARIADB_POD -n mail-stack -- \
        mysql -uroot -ppassword -e "$1" 2>/dev/null
}

# 1. Vérifier domaines actuels
echo "1️⃣ Domaines actuels dans la base:"
exec_sql "USE mailserver; SELECT * FROM virtual_domains;" || echo "⚠️  Table vide ou inexistante"
echo ""

# 2. Vérifier utilisateurs
echo "2️⃣ Utilisateurs actuels:"
exec_sql "USE mailserver; SELECT email FROM virtual_users;" || echo "⚠️  Table vide ou inexistante"
echo ""

# 3. Vérifier aliases
echo "3️⃣ Aliases actuels:"
exec_sql "USE mailserver; SELECT source, destination FROM virtual_aliases;" || echo "⚠️  Table vide ou inexistante"
echo ""

# 4. Chercher ancien domaine k8smalagasy.com
echo "4️⃣ Recherche 'k8smalagasy.com' (sans point)..."
OLD_DOMAIN_COUNT=$(exec_sql "USE mailserver; SELECT COUNT(*) FROM virtual_domains WHERE name='k8smalagasy.com';" | tail -1)

if [ "$OLD_DOMAIN_COUNT" -gt 0 ]; then
    echo "⚠️  Ancien domaine trouvé: k8smalagasy.com"
    echo ""
    echo "🔄 Correction nécessaire:"
    echo "   k8smalagasy.com → k8s.malagasy.com"
    echo ""
    
    read -p "Corriger maintenant? (y/n) " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "🔄 Application des corrections..."
        
        # Backup avant modification
        echo "💾 Backup base de données..."
        kubectl exec $MARIADB_POD -n mail-stack -- \
            mariadb-dump -uroot -ppassword mailserver \
            > /tmp/mailserver-backup-$(date +%Y%m%d-%H%M).sql
        echo "✅ Backup: /tmp/mailserver-backup-$(date +%Y%m%d-%H%M).sql"
        
        # Mise à jour domaine
        exec_sql "USE mailserver; UPDATE virtual_domains SET name='k8s.malagasy.com' WHERE name='k8smalagasy.com';"
        echo "✅ Domaine mis à jour"
        
        # Mise à jour emails utilisateurs
        exec_sql "USE mailserver; UPDATE virtual_users SET email = REPLACE(email, '@k8smalagasy.com', '@k8s.malagasy.com');"
        echo "✅ Emails utilisateurs mis à jour"
        
        # Mise à jour aliases (source)
        exec_sql "USE mailserver; UPDATE virtual_aliases SET source = REPLACE(source, '@k8smalagasy.com', '@k8s.malagasy.com');"
        echo "✅ Aliases (source) mis à jour"
        
        # Mise à jour aliases (destination)
        exec_sql "USE mailserver; UPDATE virtual_aliases SET destination = REPLACE(destination, '@k8smalagasy.com', '@k8s.malagasy.com');"
        echo "✅ Aliases (destination) mis à jour"
        
        echo ""
        echo "✅ Correction terminée"
    else
        echo "❌ Correction annulée"
    fi
else
    echo "✅ Domaine correct: k8s.malagasy.com déjà utilisé"
    echo "   (ou base vide)"
fi

echo ""
echo "=========================================="
echo "ÉTAT FINAL"
echo "=========================================="
echo ""

echo "📊 Domaines:"
exec_sql "USE mailserver; SELECT * FROM virtual_domains;" 2>/dev/null || echo "⚠️  Aucun domaine"
echo ""

echo "📊 Utilisateurs:"
exec_sql "USE mailserver; SELECT email, enabled FROM virtual_users;" 2>/dev/null || echo "⚠️  Aucun utilisateur"
echo ""

echo "📊 Aliases:"
exec_sql "USE mailserver; SELECT source, destination FROM virtual_aliases LIMIT 10;" 2>/dev/null || echo "⚠️  Aucun alias"
echo ""

echo "✅ Vérification terminée"
echo ""
echo "📝 Si base vide, créer utilisateurs avec:"
echo "   ./scripts/manage-mail-users.sh"
