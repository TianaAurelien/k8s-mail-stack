#!/bin/bash
# Script pour redémarrer workers 1 et 2 après upgrade RAM/Disk
# À exécuter SUR master-1

set -e

echo "🔄 Redémarrage workers 1 et 2 avec nouvelles ressources..."

# Fonction pour drainer un worker proprement
drain_worker() {
    local worker=$1
    echo ""
    echo "=== Drainage $worker ==="
    
    # Marquer comme non-schedulable
    kubectl cordon $worker
    
    # Évacuer tous les pods (sauf daemonsets)
    kubectl drain $worker \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --grace-period=300 \
        --timeout=600s
    
    echo "✅ $worker drainé"
}

# Fonction pour attendre qu'un worker soit prêt
wait_worker_ready() {
    local worker=$1
    echo ""
    echo "⏳ Attente redémarrage $worker..."
    
    for i in {1..60}; do
        if kubectl get node $worker 2>/dev/null | grep -q Ready; then
            echo "✅ $worker est Ready"
            return 0
        fi
        echo "Attente... ($i/60)"
        sleep 10
    done
    
    echo "❌ Timeout: $worker pas Ready après 10 minutes"
    return 1
}

# PHASE 1: Worker-1
echo ""
echo "=========================================="
echo "PHASE 1: Redémarrage worker-1"
echo "=========================================="

drain_worker k8s-worker-1

echo ""
echo "⏸️  PAUSE: Redémarrez maintenant worker-1 depuis Proxmox"
echo "   1. Dans Proxmox: VM worker-1 → Shutdown"
echo "   2. Vérifier RAM: 16 GB"
echo "   3. Vérifier Disk /dev/sdb: 150 GB"
echo "   4. Start VM"
echo ""
read -p "Appuyez sur ENTRÉE quand worker-1 a redémarré..."

wait_worker_ready k8s-worker-1

# Remettre en service
kubectl uncordon k8s-worker-1
echo "✅ worker-1 remis en service"

# Attendre stabilisation
echo "⏳ Stabilisation (60s)..."
sleep 60

# PHASE 2: Worker-2
echo ""
echo "=========================================="
echo "PHASE 2: Redémarrage worker-2"
echo "=========================================="

drain_worker k8s-worker-2

echo ""
echo "⏸️  PAUSE: Redémarrez maintenant worker-2 depuis Proxmox"
echo "   1. Dans Proxmox: VM worker-2 → Shutdown"
echo "   2. Vérifier RAM: 16 GB"
echo "   3. Vérifier Disk /dev/sdb: 150 GB"
echo "   4. Start VM"
echo ""
read -p "Appuyez sur ENTRÉE quand worker-2 a redémarré..."

wait_worker_ready k8s-worker-2

# Remettre en service
kubectl uncordon k8s-worker-2
echo "✅ worker-2 remis en service"

# Attendre stabilisation
echo "⏳ Stabilisation (60s)..."
sleep 60

# VÉRIFICATIONS FINALES
echo ""
echo "=========================================="
echo "VÉRIFICATIONS FINALES"
echo "=========================================="

echo ""
echo "📊 État des workers:"
kubectl get nodes -o wide

echo ""
echo "💾 Vérification disques Longhorn:"
for worker in k8s-worker-1 k8s-worker-2; do
    echo "=== $worker ==="
    ssh root@$worker 'df -h /mnt/longhorn | tail -1'
done

echo ""
echo "🧠 Vérification RAM:"
for worker in k8s-worker-1 k8s-worker-2; do
    echo "=== $worker ==="
    ssh root@$worker 'free -h | grep Mem'
done

echo ""
echo "📦 État des pods mail-stack:"
kubectl get pods -n mail-stack -o wide

echo ""
echo "✅ Redémarrage terminé!"
echo ""
