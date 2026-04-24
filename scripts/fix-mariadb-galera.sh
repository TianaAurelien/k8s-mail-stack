#!/bin/bash
# Correction rapide MariaDB Galera
# Problème: PVC non attachés + ConfigMap manquant

set -e

echo "🔧 Correction MariaDB Galera..."

# 1. Supprimer le déploiement actuel bloqué
echo "1️⃣ Suppression déploiement bloqué..."
kubectl delete statefulset mariadb-galera -n mail-stack --cascade=orphan 2>/dev/null || true

# Attendre un peu
sleep 5

# Forcer suppression des pods
echo "2️⃣ Nettoyage pods bloqués..."
kubectl delete pod mariadb-galera-0 mariadb-galera-1 mariadb-galera-2 -n mail-stack --force --grace-period=0 2>/dev/null || true

# Supprimer les PVC orphelins
echo "3️⃣ Suppression PVC orphelins..."
kubectl delete pvc data-mariadb-galera-0 data-mariadb-galera-1 data-mariadb-galera-2 -n mail-stack 2>/dev/null || true

# Attendre suppression
sleep 10

# 4. Créer le ConfigMap manquant
echo "4️⃣ Création ConfigMap init-scripts..."
kubectl apply -f /home/aurelien/k8s/database/mariadb-init-scripts.yaml

# Vérifier que le ConfigMap existe
if kubectl get configmap mariadb-init-scripts -n mail-stack &>/dev/null; then
    echo "✅ ConfigMap créé"
else
    echo "❌ Erreur création ConfigMap"
    exit 1
fi

# 5. Vérifier/créer ConfigMap config
echo "5️⃣ Vérification ConfigMap config..."
if ! kubectl get configmap mariadb-galera-config -n mail-stack &>/dev/null; then
    echo "⚠️  ConfigMap mariadb-galera-config manquant, création..."
    
    cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mariadb-galera-config
  namespace: mail-stack
data:
  galera.cnf: |
    [galera]
    wsrep_on = ON
    wsrep_provider = /usr/lib/galera/libgalera_smm.so
    wsrep_cluster_name = "mail_galera_cluster"
    wsrep_cluster_address = "gcomm://mariadb-galera-0.mariadb-galera,mariadb-galera-1.mariadb-galera,mariadb-galera-2.mariadb-galera"
    wsrep_node_address = "$(hostname -i)"
    wsrep_node_name = "$(hostname)"
    wsrep_sst_method = rsync
    wsrep_sst_auth = "root:password"
    binlog_format = ROW
    default_storage_engine = InnoDB
    innodb_autoinc_lock_mode = 2
    innodb_flush_log_at_trx_commit = 0
    innodb_buffer_pool_size = 512M
    wsrep_slave_threads = 2

  my.cnf: |
    [mysqld]
    user = mysql
    port = 3306
    datadir = /var/lib/mysql
    character-set-server = utf8mb4
    collation-server = utf8mb4_unicode_ci
    binlog_format = ROW
    max_connections = 500
    query_cache_type = 0
    !includedir /etc/mysql/conf.d/
EOF
fi

# 6. Redéployer MariaDB Galera
echo "6️⃣ Redéploiement MariaDB Galera..."
kubectl apply -f /home/aurelien/k8s/database/mariadb-deployment.yaml

# 7. Surveiller démarrage
echo "7️⃣ Surveillance démarrage (peut prendre 5-10 min)..."
echo ""
echo "📊 État des pods:"

# Attendre que les pods commencent
sleep 30

kubectl get pods -n mail-stack -l app=mariadb-galera

echo ""
echo "📋 Pour surveiller en temps réel:"
echo "   kubectl get pods -n mail-stack -l app=mariadb-galera -w"
echo ""
echo "📋 Logs du premier pod:"
echo "   kubectl logs mariadb-galera-0 -n mail-stack -f"
echo ""

# Vérifier les PVC
echo "💾 État des PVC:"
kubectl get pvc -n mail-stack | grep mariadb-galera

echo ""
echo "✅ Correction appliquée"
echo ""
echo "⏳ Attendre que les 3 pods soient Running (5-10 minutes)"
echo "   Puis vérifier le cluster:"
echo "   kubectl exec mariadb-galera-0 -n mail-stack -- mysql -uroot -ppassword -e \"SHOW STATUS LIKE 'wsrep_cluster_size'\""
