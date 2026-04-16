#!/bin/bash
# Tests de failover automatisés (Version Sécurisée)
# Vérifie que l'infrastructure résiste aux pannes

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[TEST]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# --- RÉCUPÉRATION SÉCURISÉE DU MOT DE PASSE ---
# On récupère le mot de passe root depuis le secret k8s pour éviter le stockage en clair
ROOT_PASS=$(kubectl get secret mail-secrets -n mail-stack -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 --decode)

if [ -z "$ROOT_PASS" ]; then
    log_error "Impossible de récupérer le mot de passe depuis le Secret mail-secrets."
    exit 1
fi

FAILED_TESTS=0

test_worker_failover() {
    local WORKER=$1
    echo ""
    log_info "=========================================="
    log_info "TEST FAILOVER: $WORKER"
    log_info "=========================================="
    
    log_info "📊 État initial sur $WORKER..."
    kubectl get pods -n mail-stack -o wide | grep "$WORKER" || log_warn "Aucun pod sur $WORKER"
    
    log_info "🔄 Drainage de $WORKER..."
    kubectl drain "$WORKER" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=300s
    
    log_info "⏳ Attente basculement (30s)..."
    sleep 30
    
    log_info "🔍 Vérification de la disponibilité des services..."
    
    # Test MariaDB Galera (Utilisation de la variable sécurisée)
    if kubectl exec mariadb-galera-0 -n mail-stack -- mysql -u root -p"${ROOT_PASS}" -e "SELECT 1" &>/dev/null; then
        log_info "  ✅ MariaDB accessible"
    else
        log_error "  ❌ MariaDB inaccessible"
        ((FAILED_TESTS++))
    fi
    
    # Test Postfix
    PF_POD=$(kubectl get pod -n mail-stack -l app=postfix -o name | head -1)
    if [ -n "$PF_POD" ] && kubectl exec "$PF_POD" -n mail-stack -- postconf mail_version &>/dev/null; then
        log_info "  ✅ Postfix accessible"
    else
        log_error "  ❌ Postfix inaccessible"
        ((FAILED_TESTS++))
    fi
    
    # Vérification Quorum Galera
    CLUSTER_SIZE=$(kubectl exec mariadb-galera-0 -n mail-stack -- mysql -u root -p"${ROOT_PASS}" -N -s -e "SHOW STATUS LIKE 'wsrep_cluster_size'" | awk '{print $2}')
    if [ "$CLUSTER_SIZE" -ge 2 ]; then
        log_info "  ✅ Quorum Galera maintenu (Size: $CLUSTER_SIZE)"
    else
        log_error "  ❌ Quorum Galera critique (Size: $CLUSTER_SIZE)"
        ((FAILED_TESTS++))
    fi
    
    log_info "🔄 Remise en service de $WORKER..."
    kubectl uncordon "$WORKER"
    sleep 10
}

# --- EXÉCUTION ---
log_info "🚀 Lancement des tests HA..."
read -p "Confirmer le drainage des nodes ? (y/n) " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

# On boucle sur les workers détectés (évite de hardcoder les noms)
for node in $(kubectl get nodes -l node-role.kubernetes.io/worker=worker -o name | cut -d/ -f2); do
    test_worker_failover "$node"
done

# Résultat Final
echo ""
if [ $FAILED_TESTS -eq 0 ]; then
    log_info "✅ TOUS LES TESTS RÉUSSIS - Infrastructure HA stable."
else
    log_error "❌ $FAILED_TESTS ERREURS DÉTECTÉES."
    exit 1
fi
