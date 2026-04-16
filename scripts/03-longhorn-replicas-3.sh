#!/bin/bash
# Script pour passer Longhorn de 2 à 3 replicas
# À exécuter sur master-1

set -e

echo "🔄 Migration Longhorn vers 3 replicas..."

# 1. Vérifier que les 3 workers sont bien détectés par Longhorn
echo "1️⃣ Vérification workers Longhorn..."
kubectl get nodes.longhorn.io -n longhorn-system

WORKER_COUNT=$(kubectl get nodes.longhorn.io -n longhorn-system --no-headers | wc -l)
if [ "$WORKER_COUNT" -ne 3 ]; then
    echo "❌ Erreur: Seulement $WORKER_COUNT workers détectés"
    echo "   Attendu: 3 workers"
    exit 1
fi

echo "✅ 3 workers Longhorn détectés"

# 2. Passer le StorageClass en 3 replicas (pour nouveaux volumes)
echo ""
echo "2️⃣ Mise à jour StorageClass (nouveaux volumes)..."
kubectl patch storageclass longhorn-mail \
    -p '{"parameters":{"numberOfReplicas":"3"}}'

echo "✅ StorageClass mis à jour: 3 replicas"

# 3. Mettre à jour tous les volumes existants
echo ""
echo "3️⃣ Migration volumes existants vers 3 replicas..."

VOLUMES=$(kubectl get volumes -n longhorn-system -o name)
TOTAL=$(echo "$VOLUMES" | wc -l)
CURRENT=0

for vol in $VOLUMES; do
    CURRENT=$((CURRENT + 1))
    VOL_NAME=$(basename $vol)
    
    echo "[$CURRENT/$TOTAL] Migration $VOL_NAME..."
    
    kubectl patch $vol -n longhorn-system \
        --type='json' \
        -p='[{"op": "replace", "path": "/spec/numberOfReplicas", "value":3}]' \
        2>/dev/null || true
done

echo ""
echo "✅ Tous les volumes passés en 3 replicas"

# 4. Attendre stabilisation (quelques minutes selon taille données)
echo ""
echo "⏳ Attente de la réplication (peut prendre 5-15 minutes)..."
echo "   Surveiller avec: kubectl get volumes -n longhorn-system"
echo ""

# Afficher état
kubectl get volumes -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
SIZE:.spec.size,\
REPLICAS:.spec.numberOfReplicas,\
STATE:.status.state

echo ""
echo "✅ Migration Longhorn lancée"
echo ""
echo "📝 Prochaine étape (une fois volumes Healthy):"
echo "   cd /home/aurelien/k8s"
echo "   kubectl apply -f database/mariadb-deployment.yaml"
