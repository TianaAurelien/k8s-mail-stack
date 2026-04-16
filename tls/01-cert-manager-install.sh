#!/bin/bash
# tls/01-cert-manager-install.sh
# Installation de cert-manager v1.13.0
echo "--- Mise à jour des CRDs et de l'installation de cert-manager v1.15.4 ---"

# 1. On applique les ressources officielles (CRDs incluses)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.4/cert-manager.yaml
