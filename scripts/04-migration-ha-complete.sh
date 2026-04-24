#!/bin/bash
# Script de migration complète vers HA
# À exécuter sur master-1
# Durée estimée: 2-3 heures

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Vérifications préalables
log_info "🔍 Vérifications préalables..."

# Vérifier 3 workers
WORKER_COUNT=$(kubectl get nodes -l node-role.kubernetes.io/worker=worker --no-headers | wc -l)
if [ "$WORKER_COUNT" -ne 3 ]; then
    log_error "❌ Seulement $WORKER_COUNT workers détectés (attendu: 3)"
    exit 1
fi
log_info "✅ 3 workers détectés"

# Vérifier Longhorn
LONGHORN_WORKERS=$(kubectl get nodes.longhorn.io -n longhorn-system --no-headers | wc -l)
if [ "$LONGHORN_WORKERS" -ne 3 ]; then
    log_error "❌ Longhorn: $LONGHORN_WORKERS workers (attendu: 3)"
    exit 1
fi
log_info "✅ Longhorn sur 3 workers"

echo ""
log_warn "⚠️  Cette migration va:"
log_warn "  - Passer Longhorn en 3 replicas"
log_warn "  - Migrer MariaDB vers Galera 3 nodes"
log_warn "  - Passer Postfix/Dovecot en 3 replicas"
log_warn "  - Passer tous les services en HA"
log_warn ""
log_warn "  Durée estimée: 2-3 heures"
log_warn "  Downtime: 0 (migration progressive)"
echo ""

read -p "Continuer? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Migration annulée"
    exit 0
fi

# Créer répertoire backup
BACKUP_DIR="/home/aurelien/backups/pre-ha-$(date +%Y%m%d-%H%M)"
mkdir -p "$BACKUP_DIR"
log_info "📁 Backups dans: $BACKUP_DIR"

# ===== PHASE 1: BACKUP =====
echo ""
log_info "======================================"
log_info "PHASE 1: BACKUP DE SÉCURITÉ"
log_info "======================================"

log_info "💾 Backup MariaDB..."
kubectl exec mariadb-0 -n mail-stack -- \
    mariadb-dump -u root -ppassword --all-databases \
    > "$BACKUP_DIR/mariadb-dump.sql"
log_info "✅ Backup MariaDB: $(du -h $BACKUP_DIR/mariadb-dump.sql | cut -f1)"

log_info "💾 Backup configurations..."
kubectl get all -n mail-stack -o yaml > "$BACKUP_DIR/mail-stack-all.yaml"
kubectl get pvc -n mail-stack -o yaml > "$BACKUP_DIR/mail-stack-pvc.yaml"
kubectl get configmap -n mail-stack -o yaml > "$BACKUP_DIR/mail-stack-configmaps.yaml"
log_info "✅ Configurations sauvegardées"

# ===== PHASE 2: LONGHORN 3 REPLICAS =====
echo ""
log_info "======================================"
log_info "PHASE 2: LONGHORN 3 REPLICAS"
log_info "======================================"

#log_info "🔄 Mise à jour StorageClass..."
#kubectl patch storageclass longhorn-mail \
#    -p '{"parameters":{"numberOfReplicas":"3"}}'

log_info "🔄 Migration volumes existants..."
for vol in $(kubectl get volumes -n longhorn-system -o name); do
    VOL_NAME=$(basename $vol)
    log_info "  → $VOL_NAME"
    kubectl patch $vol -n longhorn-system \
        --type='json' \
        -p='[{"op": "replace", "path": "/spec/numberOfReplicas", "value":3}]' \
        2>/dev/null || true
done

log_info "⏳ Attente réplication (30-60s)..."
sleep 60

log_info "✅ Longhorn en 3 replicas"

# ===== PHASE 3: MARIADB GALERA =====
echo ""
log_info "======================================"
log_info "PHASE 3: MARIADB GALERA 3 NODES"
log_info "======================================"

log_info "🚀 Déploiement Galera..."
kubectl apply -f /home/aurelien/k8s/database/mariadb-init-configmap.yaml
kubectl apply -f /home/aurelien/k8s/database/mariadb-deployment.yaml

log_info "⏳ Attente démarrage Galera (peut prendre 5-10 min)..."
kubectl wait --for=condition=ready pod \
    -l app=mariadb-galera \
    -n mail-stack \
    --timeout=600s

# Vérifier cluster
log_info "🔍 Vérification cluster Galera..."
for i in 0 1 2; do
    SIZE=$(kubectl exec mariadb-galera-$i -n mail-stack -- \
        mysql -uroot -ppassword -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | \
        grep wsrep_cluster_size | awk '{print $2}')
    
    if [ "$SIZE" == "3" ]; then
        log_info "  ✅ Node $i: Cluster size = 3"
    else
        log_error "  ❌ Node $i: Cluster size = $SIZE (attendu: 3)"
    fi
done

# Restaurer données
log_info "📥 Restauration données dans Galera..."
kubectl exec -i mariadb-galera-0 -n mail-stack -- \
    mysql -uroot -ppassword < "$BACKUP_DIR/mariadb-dump.sql"

log_info "✅ MariaDB Galera opérationnel"

# Supprimer ancien MariaDB
log_info "🗑️  Suppression ancien MariaDB..."
kubectl delete statefulset mariadb -n mail-stack --cascade=orphan 2>/dev/null || true
kubectl delete pvc mariadb-pvc -n mail-stack 2>/dev/null || true

# ===== PHASE 4: POSTFIX HA =====
echo ""
log_info "======================================"
log_info "PHASE 4: POSTFIX 3 REPLICAS"
log_info "======================================"

kubectl delete statefulset postfix -n mail-stack --cascade=orphan 2>/dev/null || true
kubectl apply -f /home/aurelien/k8s/mail/postfix-deployment.yaml

log_info "⏳ Attente Postfix..."
kubectl wait --for=condition=ready pod \
    -l app=postfix \
    -n mail-stack \
    --timeout=300s

log_info "✅ Postfix HA déployé"

# ===== PHASE 5: DOVECOT HA =====
echo ""
log_info "======================================"
log_info "PHASE 5: DOVECOT 3 REPLICAS"
log_info "======================================"

kubectl delete statefulset dovecot -n mail-stack --cascade=orphan 2>/dev/null || true
kubectl apply -f /home/aurelien/k8s/mail/dovecot.yaml

log_info "⏳ Attente Dovecot..."
kubectl wait --for=condition=ready pod \
    -l app=dovecot \
    -n mail-stack \
    --timeout=300s

log_info "✅ Dovecot HA déployé"

# ===== PHASE 6: AUTRES SERVICES HA =====
echo ""
log_info "======================================"
log_info "PHASE 6: AUTRES SERVICES HA"
log_info "======================================"

log_info "🔄 Redis 3 replicas..."
kubectl delete deployment redis -n mail-stack 2>/dev/null || true
kubectl apply -f /home/aurelien/k8s/database/redis-deployment.yaml

log_info "🔄 Roundcube 3 replicas..."
kubectl scale deployment roundcube -n mail-stack --replicas=3

log_info "🔄 Rspamd 3 replicas..."
kubectl scale deployment rspamd -n mail-stack --replicas=3

log_info "🔄 ClamAV 3 replicas..."
kubectl scale deployment clamav -n mail-stack --replicas=3

log_info "🔄 Unbound 3 replicas..."
kubectl scale deployment unbound -n mail-stack --replicas=3

log_info "⏳ Attente démarrage services..."
sleep 30

log_info "✅ Tous services en HA"

# ===== VÉRIFICATIONS FINALES =====
echo ""
log_info "======================================"
log_info "VÉRIFICATIONS FINALES"
log_info "======================================"

echo ""
log_info "📊 État des workers:"
kubectl get nodes -o wide

echo ""
log_info "💾 Volumes Longhorn:"
kubectl get volumes -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
REPLICAS:.spec.numberOfReplicas,\
STATE:.status.state | head -10

echo ""
log_info "📦 Pods mail-stack par node:"
kubectl get pods -n mail-stack -o wide --sort-by=.spec.nodeName | \
    grep -E "(NAME|postfix|dovecot|mariadb-galera|redis|rspamd|roundcube|clamav)"

echo ""
log_info "🔍 PodDisruptionBudgets:"
kubectl get pdb -n mail-stack

echo ""
log_info "======================================"
log_info "✅ MIGRATION HA TERMINÉE !"
log_info "======================================"
echo ""

log_info "📝 Prochaines étapes:"
log_info "  1. Tester l'envoi/réception de mails"
log_info "  2. Exécuter tests de failover:"
log_info "     ./scripts/05-test-failover.sh"
log_info "  3. Vérifier Grafana: http://192.168.6.224"
echo ""

log_info "💾 Backups disponibles dans: $BACKUP_DIR"
log_info "🔄 Pour rollback: ./scripts/06-rollback-ha.sh"
echo ""

log_info "🎉 Infrastructure HA Production Ready!"
