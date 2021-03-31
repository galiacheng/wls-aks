#!/bin/bash

echo scale down action >> scaledown.log

MASTER=https://haicheakscnipublic-dns-069d2dd0.hcp.southeastasia.azmk8s.io:443

echo Kubernetes master is $MASTER

source /var/scripts/scalingAction.sh \
  --action=scaleDown \
  --domain_uid=sample-domain1 \
  --cluster_name=cluster-1 \
  --kubernetes_master=${MASTER} \
  --wls_domain_namespace=sample-domain1-ns \
  --operator_service_name=internal-weblogic-operator-svc \
  --operator_service_account=sample-weblogic-operator-sa \
  --operator_namespace=sample-weblogic-operator-ns \
  --scaling_size=1