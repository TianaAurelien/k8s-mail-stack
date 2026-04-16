# scripts/check-connectivity.sh
#!/bin/bash
echo "🔍 Vérification de la connectivité interne du Mail-Stack..."

check_port() {
    local POD=$1
    local HOST=$2
    local PORT=$3
    echo -n "Test $POD -> $HOST:$PORT : "
    if kubectl exec -n mail-stack $POD -- bash -c "timeout 1 bash -c 'cat < /dev/null > /dev/tcp/$HOST/$PORT'" 2>/dev/null; then
        echo -e "✅ OK"
    else
        echo -e "❌ ÉCHEC"
    fi
}

# Tests critiques
check_port "postfix-0" "mariadb-service" "3306"
check_port "postfix-0" "dovecot-service" "10000"
check_port "dovecot-0" "mariadb-service" "3306"
check_port "roundcube-$(kubectl get pods -n mail-stack -l app=roundcube -o jsonpath='{.items[0].metadata.name}')" "mariadb-service" "3306"
