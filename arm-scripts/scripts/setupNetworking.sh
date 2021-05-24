# Copyright (c) 2019, 2020, Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

echo "Script starts"

#Function to output message to stdout
function echo_stderr() {
    echo "$@" >&2
    echo "$@" >>stdout
}

function echo_stdout() {
    echo "$@" >&2
    echo "$@" >>stdout
}

#Function to display usage message
function usage() {
    echo_stdout "./setupNetworking.sh <ocrSSOUser> "
    if [ $1 -eq 1 ]; then
        exit 1
    fi
}

# Validate teminal status with $?, exit with exception if errors happen.
function validate_status() {
    if [ $? == 1 ]; then
        echo_stderr "$@"
        echo_stderr "Errors happen, exit 1."
        exit 1
    else
        echo_stdout "$@"
    fi
}

# Install latest kubectl and helm
function install_utilities() {
    if [ -d "apps" ]; then
        rm apps -f -r
    fi

    mkdir apps
    cd apps

    # Install kubectl
    az aks install-cli
    echo "kubectl version"
    ret=$(kubectl --help)
    validate_status ${ret}
}

#Function to validate input
function validate_input() {
    if [[ -z "$aksClusterRGName" || -z "${aksClusterName}" ]]; then
        echo_stderr "AKS cluster name and resource group name are required. "
        usage 1
    fi
}

# Connect to AKS cluster
function connect_aks_cluster() {
    az aks get-credentials --resource-group ${aksClusterRGName} --name ${aksClusterName} --overwrite-existing
}

function generate_admin_lb_definicion() {
    cat <<EOF >${scriptDir}/admin-server-lb.yaml
apiVersion: v1
kind: Service
metadata:
  name: ${adminServerLBSVCName}
  namespace: ${wlsDomainNS}
EOF

    # to create internal load balancer service
    if [[ "${enableInternalLB,,}" == "true" ]];then
        cat <<EOF >>${scriptDir}/admin-server-lb.yaml
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
EOF
    fi

cat <<EOF >>${scriptDir}/admin-server-lb.yaml
spec:
  ports:
  - name: default
    port: ${adminLBPort}
    protocol: TCP
    targetPort: ${adminTargetPort}
  selector:
    weblogic.domainUID: ${wlsDomainUID}
    weblogic.serverName: ${adminServerName}
  sessionAffinity: None
  type: LoadBalancer
EOF
}

function generate_cluster_lb_definicion() {
    cat <<EOF >${scriptDir}/cluster-lb.yaml
apiVersion: v1
kind: Service
metadata:
  name: ${clusterLBSVCName}
  namespace: ${wlsDomainNS}
EOF

    # to create internal load balancer service
    if [[ "${enableInternalLB,,}" == "true" ]];then
        cat <<EOF >>${scriptDir}/cluster-lb.yaml
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
EOF
    fi

    cat <<EOF >>${scriptDir}/cluster-lb.yaml
spec:
  ports:
  - name: default
    port: ${clusterLBPort}
    protocol: TCP
    targetPort: ${clusterTargetPort}
  selector:
    weblogic.domainUID: ${wlsDomainUID}
    weblogic.clusterName: ${clusterName}
  sessionAffinity: None
  type: LoadBalancer
EOF
}

function query_admin_target_port() {
  adminTargetPort=$(kubectl describe service ${svcAdminServer} -n ${wlsDomainNS} | grep 'TargetPort:' | tr -d -c 0-9)
  validate_status "Query admin target port."
  echo "Target port of ${adminServerName}: ${adminTargetPort}"
}

function query_cluster_target_port() {
  clusterTargetPort=$(kubectl describe service ${svcCluster} -n ${wlsDomainNS} | grep 'TargetPort:' | tr -d -c 0-9)
  validate_status "Query cluster 1 target port."
  echo "Target port of ${clusterName}: ${clusterTargetPort}"
}

function create_svc_lb() {
  # No lb svc inputs
  if [[ "${lbSvcValues}" == "[]" ]]; then
    return
  fi

  query_admin_target_port
  query_cluster_target_port

  # Parse lb svc input values
  # Generate valid json
  ret=$(echo $lbSvcValues | sed  "s/\:/\\\"\:\\\"/g" \
    | sed  "s/{/{\"/g" \
    | sed  "s/}/\"}/g" \
    | sed  "s/,/\",\"/g" \
    | sed "s/}\",\"{/},{/g" \
    | tr -d \(\))

  cat <<EOF >${scriptDir}/lbConfiguration.json
${ret}
EOF

  array=$(jq  -r '.[] | "\(.colName),\(.colTarget),\(.colPort)"' ${scriptDir}/lbConfiguration.json)
  for item in $array; do
    # LB config for admin-server
    target=$(cut -d',' -f2 <<<$item)
    if [[ "${target}" == "adminServer" ]];then
      adminServerLBSVCNamePrefix=$(cut -d',' -f1 <<<$item)
      adminServerLBSVCName="${adminServerLBSVCName}-svc-lb"
      adminLBPort=$(cut -d',' -f3 <<<$item)
      generate_admin_lb_definicion
      kubectl apply -f ${scriptDir}/admin-server-lb.yaml
      waitfor_svc_completed ${adminServerLBSVCName}
    else
      clusterLBSVCNamePrefix=$(cut -d',' -f1 <<<$item)
      clusterLBSVCName="${clusterLBSVCNamePrefix}-svc-lb"
      clusterLBPort=$(cut -d',' -f3 <<<$item)
      generate_cluster_lb_definicion
      kubectl apply -f ${scriptDir}/cluster-lb.yaml
      waitfor_svc_completed ${clusterLBSVCName}
    fi
  done
}

function install_helm() {
  # Install helm
  browserURL=$(curl -s https://api.github.com/repos/helm/helm/releases/latest  \
  | grep "browser_download_url.*linux-amd64.tar.gz.asc" \
  | cut -d : -f 2,3 \
  | tr -d \")
  helmLatestVersion=${browserURL#*download\/}
  helmLatestVersion=${helmLatestVersion%%\/helm*}
  helmPackageName=helm-${helmLatestVersion}-linux-amd64.tar.gz
  curl -LO -s https://get.helm.sh/${helmPackageName}
  tar -zxvf ${helmPackageName}
  chmod +x linux-amd64/helm
  mv linux-amd64/helm /usr/local/bin/helm
  echo "helm version"
  helm version
  validate_status "Finished installing helm."
}

function network_peers_aks_appgw() {
  aksLocation=$(az aks show --name ${aksClusterName}  -g ${aksClusterRGName} -o tsv --query "location")
  aksMCRGName="MC_${aksClusterRGName}_${aksClusterName}_${aksLocation}"
  ret=$(az group exists ${aksMCRGName})
  if [ "${ret,,}" == "false" ];then
    echo_stderr "AKS namaged resource group ${aksMCRGName} does not exist."
    exit 1
  fi

  aksNetWorkId=$( az resource list -g ${aksMCRGName} --resource-type Microsoft.Network/virtualNetworks -o tsv --query '[*].id')
  az network vnet peering create \
    --name aks-appgw-peer \
    --remote-vnet ${aksNetWorkId} \
    --resource-group ${curRGName} \
    --vnet-name ${vnetName} \
    --allow-vnet-access
}

function create_appgw_ingress() {
  if [[  "${enableAppGWIngress,,}" != "true"  ]];then
    return
  fi

  query_cluster_target_port

  # create sa and bind cluster-admin role
  kubectl apply -f ${scriptDir}/appgw-ingress-clusterAdmin-roleBinding.yaml

  # Install aad pod identity controller
  # https://github.com/Azure/aad-pod-identity
  # latestAADPodIdentity=$(curl -s https://api.github.com/repos/Azure/aad-pod-identity/releases/latest  \
  # | grep "browser_download_url.*deployment-rbac.yaml" \
  # | cut -d : -f 2,3 \
  # | tr -d \")

  # kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/v1.8.0/deploy/infra/deployment-rbac.yaml

  install_helm

  helm repo add application-gateway-kubernetes-ingress ${appgwIngressHelmRepo}
  helm repo update

  # Keep the identity parsing, may be used for CNI network usage
  # {type:UserAssigned,userAssignedIdentities:{/subscriptions/05887623-95c5-4e50-a71c-6e1c738794e2/resourceGroups/haiche-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/wls-aks-mvp:{}}}
  # identityId=${identity#*userAssignedIdentities:\{}
  # identityId=${identityId%%:\{\}*}
  # query identity client id
  # identityClientId=$(az identity show --ids ${identityId} -o tsv --query "clientId")
  
  # TODO: workaround for MVP demo, only for users with sub owner role.
  spBase64String=$(az ad sp create-for-rbac --name ${spName} --sdk-auth | base64 -w0)

  # generate helm config
  customAppgwHelmConfig=${scriptDir}/agggw-helm-config.yaml
  cp ${scriptDir}/agggw-helm-config.yaml.template ${customAppgwHelmConfig}
  subID=$(echo $subID | tr -d '/subscriptions/')
  sed -i -e "s:@SUB_ID@:${subID}:g" ${customAppgwHelmConfig}
  sed -i -e "s:@APPGW_RG_NAME@:${curRGName}:g" ${customAppgwHelmConfig}
  sed -i -e "s:@APPGW_NAME@:${appgwName}:g" ${customAppgwHelmConfig}
  sed -i -e "s:@WATCH_NAMESPACE@:${wlsDomainNS}:g" ${customAppgwHelmConfig}
  # sed -i -e "s:@INDENTITY_ID@:${identityId}:g" ${customAppgwHelmConfig}
  # sed -i -e "s:@IDENTITY_CLIENT_ID@:${identityClientId}:g" ${customAppgwHelmConfig}
  sed -i -e "s:@SP_ENCODING_CREDENTIALS@:${spBase64String}:g" ${customAppgwHelmConfig}

  helm install ingress-azure \
    -f ${customAppgwHelmConfig} \
    application-gateway-kubernetes-ingress/ingress-azure \
    --version 1.4.0

  validate_status "Install app gateway ingress controller."
  ret=$(kubectl get pod  | grep "ingress-azure")
  if [ -z "${ret}" ];then
  echo_stderr "Failed to install app gateway ingress controller."
    exit 1
  fi

  # generate ingress svc config
  appgwIngressSvcConfig=${scriptDir}/azure-ingress-appgateway.yaml
  cp ${scriptDir}/azure-ingress-appgateway.yaml.template ${appgwIngressSvcConfig}
  ingressSvcName="${wlsDomainUID}-appgw-ingress-svc"
  sed -i -e "s:@INGRESS_NAME@:${ingressSvcName}:g" ${appgwIngressSvcConfig}
  sed -i -e "s:@NAMESPACE@:${wlsDomainNS}:g" ${appgwIngressSvcConfig}
  sed -i -e "s:@CLUSTER_SERVICE_NAME@:${svcCluster}:g" ${appgwIngressSvcConfig}
  sed -i -e "s:@TARGET_PORT@:${clusterTargetPort}:g" ${appgwIngressSvcConfig}

  kubectl apply -f ${appgwIngressSvcConfig}
  validate_status "Create appgw ingress svc."
  waitfor_svc_completed ${ingressSvcName}

  # delete sp
  spAppId=$(az ad sp list --display-name ${spName} --query "[*].appId" -o tsv)
  az ad sp delete --id ${spAppId}
  validate_status "Deleting service principal"
}

function waitfor_svc_completed() {
  svcName=$1

  attempts=0
  svcState="running"
  while [ ! "$svcState" == "completed" ] && [ $attempts -lt 10 ]; do
      svcState="completed"
      attempts=$((attempts + 1))
      echo Waiting for job completed...${attempts}
      sleep 30

      ret=$(kubectl get svc ${svcName} -n ${wlsDomainNS} \
        | grep -c "Running")
      if [ -z "${ret}" ]; then
        svcState="running"
      fi
  done
}

# Main script
export script="${BASH_SOURCE[0]}"
export scriptDir="$(cd "$(dirname "${script}")" && pwd)"

export aksClusterRGName=$1
export aksClusterName=$2
export wlsDomainName=$3
export wlsDomainUID=$4
export lbSvcValues=$5
export enableAppGWIngress=$6
export subID=$7
export curRGName=${8}
export appgwName=${9}
export vnetName=${10}
export spBase64String=${11}

export adminServerName="admin-server"
export appgwIngressHelmRepo="https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/"
export clusterName="cluster-1"
export spName="wls-test-${timestamp}"
export svcAdminServer="${wlsDomainUID}-${adminServerName}"
export svcCluster="${wlsDomainUID}-cluster-${clusterName}"
export timestamp=$(date +%s)
export wlsDomainNS="${wlsDomainUID}-ns"

echo $lbSvcValues

validate_input

install_utilities

connect_aks_cluster

create_svc_lb

create_appgw_ingress