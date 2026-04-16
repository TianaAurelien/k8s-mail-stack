#!/bin/bash
# scripts/check-pre-requirements.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

WORKERS=("k8s-worker-1" "k8s-worker-2" "k8s-worker-3")
MOUNT_PATH="/mnt/longhorn"
REQUIRED_MODS=("dm_crypt" "iscsi_tcp")

echo -e "${YELLOW}🔍 Vérification des pré-requis sur les Workers...${NC}"
GLOBAL_ERROR=0

for NODE in "${WORKERS[@]}"; do
    echo -e "\n📡 Test de : ${GREEN}$NODE${NC}"
    
    # 1. Test SSH
    if ! ssh -o ConnectTimeout=2 "$NODE" "exit" 2>/dev/null; then
        echo -e "  ${RED}[ERREUR] Impossible de joindre le worker en SSH${NC}"
        GLOBAL_ERROR=1
        continue
    fi

    # 2. Vérification du Montage
    if ssh "$NODE" "mountpoint -q $MOUNT_PATH"; then
        echo -e "  [OK] Disque monté sur $MOUNT_PATH"
    else
        echo -e "  ${RED}[ERREUR] Disque NON monté sur $MOUNT_PATH${NC}"
        GLOBAL_ERROR=1
    fi

    # 3. Vérification des modules Kernel
    for MOD in "${REQUIRED_MODS[@]}"; do
        if ssh "$NODE" "lsmod | grep -q $MOD"; then
            echo -e "  [OK] Module $MOD chargé"
        else
            echo -e "  ${RED}[ERREUR] Module $MOD manquant (Faire: sudo modprobe $MOD)${NC}"
            GLOBAL_ERROR=1
        fi
    done
done

exit $GLOBAL_ERROR
