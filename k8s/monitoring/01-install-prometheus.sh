#!/bin/bash
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin \
  --set grafana.service.type=LoadBalancer \
  --set grafana.service.loadBalancerIP=192.168.6.224 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn-mail \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set prometheus.prometheusSpec.retention=10d \
  --set prometheus.prometheusSpec.resources.requests.memory=1Gi \
  --set prometheus.prometheusSpec.resources.limits.memory=2Gi \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClassName=longhorn-mail \
  --set grafana.persistence.size=2Gi \
  --set prometheus.service.type=LoadBalancer \
  --set prometheus.service.loadBalancerIP=192.168.6.225
