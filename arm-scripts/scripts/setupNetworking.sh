# Copyright (c) 2019, 2020, Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

echo "Script  ${0} starts"

#Function to output message to stdout
function echo_stderr() {
  echo "$@" >&2
  echo "$@" >>stdout
}

function echo_stdout() {
  echo "$@" >&2
  echo "$@" >>stdout
}

function install_helm() {
  # Install helm
  browserURL=$(curl -s https://api.github.com/repos/helm/helm/releases/latest |
    grep "browser_download_url.*linux-amd64.tar.gz.asc" |
    cut -d : -f 2,3 |
    tr -d \")
  helmLatestVersion=${browserURL#*download\/}
  helmLatestVersion=${helmLatestVersion%%\/helm*}
  helmPackageName=helm-${helmLatestVersion}-linux-amd64.tar.gz
  curl -m 120 -fL https://get.helm.sh/${helmPackageName} -o /tmp/${helmPackageName}
  tar -zxvf /tmp/${helmPackageName} -C /tmp
  mv /tmp/linux-amd64/helm /usr/local/bin/helm
  echo "helm version"
  helm version
  validate_status "Finished installing helm."
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

#Output value to deployment scripts
function output_result() {
  echo ${adminConsoleEndpoint}
  echo ${clusterEndpoint}

  result=$(jq -n -c \
    --arg adminEndpoint $adminConsoleEndpoint \
    --arg clusterEndpoint $clusterEndpoint \
    '{adminConsoleEndpoint: $adminEndpoint, clusterEndpoint: $clusterEndpoint}')
  echo "result is: $result"
  echo $result >$AZ_SCRIPTS_OUTPUT_PATH
}

#Function to display usage message
function usage() {
  echo_stdout "./setupNetworking.sh <aksClusterRGName> <aksClusterName> <wlsDomainName> <wlsDomainUID> <lbSvcValues> <enableAppGWIngress> <subID> <curRGName> <appgwName> <vnetName> <spBase64String> <appgwForAdminServer> <enableCustomDNSAlias> <dnsRGName> <dnsZoneName> <dnsAdminLabel> <dnsClusterLabel> <appgwAlias> <enableInternalLB> <appgwFrontendSSLCertData> <appgwFrontendSSLCertPsw> "
  if [ $1 -eq 1 ]; then
    exit 1
  fi
}

#Validate teminal status with $?, exit with exception if errors happen.
function validate_status() {
  if [ $? == 1 ]; then
    echo_stderr "$@"
    echo_stderr "Errors happen, exit 1."
    exit 1
  else
    echo_stdout "$@"
  fi
}

function waitfor_svc_completed() {
  svcName=$1

  attempts=0
  svcState="running"
  while [ ! "$svcState" == "completed" ] && [ $attempts -lt ${perfSVCAttemps} ]; do
    svcState="completed"
    attempts=$((attempts + 1))
    echo Waiting for job completed...${attempts}
    sleep ${perfRetryInterval}

    ret=$(kubectl get svc ${svcName} -n ${wlsDomainNS} |
      grep -c "Running")
    if [ -z "${ret}" ]; then
      svcState="running"
    fi
  done
}

#Function to validate input
function validate_input() {
  if [[ -z "$aksClusterRGName" || -z "${aksClusterName}" ]]; then
    echo_stderr "AKS cluster name and resource group name are required. "
    usage 1
  fi

  if [[ -z "$wlsDomainName" || -z "${wlsDomainUID}" ]]; then
    echo_stderr "WebLogic domain name and WebLogic domain UID are required. "
    usage 1
  fi

  if [ -z "$lbSvcValues" ]; then
    echo_stderr "lbSvcValues is required. "
    usage 1
  fi

  if [ -z "$enableAppGWIngress" ]; then
    echo_stderr "enableAppGWIngress is required. "
    usage 1
  fi

  if [ -z "$subID" ]; then
    echo_stderr "subID is required. "
    usage 1
  fi

  if [ -z "$curRGName" ]; then
    echo_stderr "curRGName is required. "
    usage 1
  fi

  if [ -z "$appgwName" ]; then
    echo_stderr "appgwName is required. "
    usage 1
  fi

  if [ -z "$vnetName" ]; then
    echo_stderr "vnetName is required. "
    usage 1
  fi

  if [ -z "$spBase64String" ]; then
    echo_stderr "spBase64String is required. "
    usage 1
  fi

  if [ -z "$appgwForAdminServer" ]; then
    echo_stderr "appgwForAdminServer is required. "
    usage 1
  fi

  if [ -z "$enableCustomDNSAlias" ]; then
    echo_stderr "enableCustomDNSAlias is required. "
    usage 1
  fi

  if [[ -z "$dnsRGName" || -z "${dnsZoneName}" ]]; then
    echo_stderr "dnsZoneName and dnsRGName are required. "
    usage 1
  fi

  if [ -z "$dnsAdminLabel" ]; then
    echo_stderr "dnsAdminLabel is required. "
    usage 1
  fi

  if [ -z "$dnsClusterLabel" ]; then
    echo_stderr "dnsClusterLabel is required. "
    usage 1
  fi

  if [ -z "$appgwAlias" ]; then
    echo_stderr "appgwAlias is required. "
    usage 1
  fi

  if [ -z "$enableInternalLB" ]; then
    echo_stderr "enableInternalLB is required. "
    usage 1
  fi
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
  if [[ "${enableInternalLB,,}" == "true" ]]; then
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
  if [[ "${enableInternalLB,,}" == "true" ]]; then
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

function generate_appgw_cluster_config_file_expose_https()
{
  export clusterIngressHttpsName=${wlsDomainUID}-cluster-appgw-ingress-https-svc
  export clusterAppgwIngressHttpsYamlPath=${scriptDir}/appgw-cluster-ingress-https-svc.yaml
  cat <<EOF >${clusterAppgwIngressHttpsYamlPath}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${clusterIngressHttpsName}
  namespace: ${wlsDomainNS}
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
spec:
  tls:
  - secretName: ${appgwFrontendSecretName}
  rules:
    - http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: ${svcCluster}
              port:
                number: ${clusterTargetPort}
EOF
}

function generate_appgw_cluster_config_file_nossl()
{
  export clusterIngressName=${wlsDomainUID}-cluster-appgw-ingress-svc
  export clusterAppgwIngressYamlPath=${scriptDir}/appgw-cluster-ingress-svc.yaml
  cat <<EOF >${clusterAppgwIngressYamlPath}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${clusterIngressName}
  namespace: ${wlsDomainNS}
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
spec:
  rules:
    - http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: ${svcCluster}
              port:
                number: ${clusterTargetPort}
EOF
}

function generate_appgw_cluster_config_file_ssl()
{
  export clusterIngressName=${wlsDomainUID}-cluster-appgw-ingress-svc
  export clusterAppgwIngressYamlPath=${scriptDir}/appgw-cluster-ingress-svc.yaml
  cat <<EOF >${clusterAppgwIngressYamlPath}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${clusterIngressName}
  namespace: ${wlsDomainNS}
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
    appgw.ingress.kubernetes.io/backend-protocol: "https"
EOF
    if [[ "${enableCustomDNSAlias,,}" == "true" ]];then
    cat <<EOF >>${clusterAppgwIngressYamlPath}
    appgw.ingress.kubernetes.io/backend-hostname: "${dnsClusterLabel}.${dnsZoneName}"
EOF
  else
    cat <<EOF >>${clusterAppgwIngressYamlPath}
    appgw.ingress.kubernetes.io/backend-hostname: "${appgwAlias}"
EOF
  fi

cat <<EOF >>${clusterAppgwIngressYamlPath}
    appgw.ingress.kubernetes.io/appgw-trusted-root-certificate: "${appgwBackendSecretName}"

spec:
  tls:
  - secretName: ${appgwFrontendSecretName}
  rules:
    - http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: ${svcCluster}
              port:
                number: ${clusterTargetPort}
EOF
}

function generate_appgw_admin_config_file_nossl()
{
  export adminIngressName=${wlsDomainUID}-admin-appgw-ingress-svc
  export adminAppgwIngressYamlPath=${scriptDir}/appgw-admin-ingress-svc.yaml
  cat <<EOF >${adminAppgwIngressYamlPath}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${adminIngressName}
  namespace: ${wlsDomainNS}
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
spec:
  rules:
    - http:
        paths:
        - path: /console*
          pathType: Prefix
          backend:
            service:
              name: ${svcAdminServer}
              port:
                number: ${adminTargetPort}
EOF
}

function generate_appgw_admin_config_file_ssl()
{
  export adminIngressName=${wlsDomainUID}-admin-appgw-ingress-svc
  export adminAppgwIngressYamlPath=${scriptDir}/appgw-admin-ingress-svc.yaml
  cat <<EOF >${adminAppgwIngressYamlPath}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${adminIngressName}
  namespace: ${wlsDomainNS}
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
    appgw.ingress.kubernetes.io/backend-protocol: "https"
EOF

  if [[ "${enableCustomDNSAlias,,}" == "true" ]];then
    cat <<EOF >>${adminAppgwIngressYamlPath}
    appgw.ingress.kubernetes.io/backend-hostname: "${dnsAdminLabel}.${dnsZoneName}"
EOF
  else
    cat <<EOF >>${adminAppgwIngressYamlPath}
    appgw.ingress.kubernetes.io/backend-hostname: "${appgwAlias}"
EOF
  fi

  cat <<EOF >>${adminAppgwIngressYamlPath}
    appgw.ingress.kubernetes.io/appgw-trusted-root-certificate: "${appgwBackendSecretName}"

spec:
  tls:
  - secretName: ${appgwFrontendSecretName}
  rules:
    - http:
        paths:
        - path: /console*
          pathType: Prefix
          backend:
            service:
              name: ${svcAdminServer}
              port:
                number: ${adminTargetPort}
EOF
}

function generate_appgw_cluster_config_file() {
  if [[ "${enableCustomSSL,,}" == "true" ]];then
    generate_appgw_cluster_config_file_ssl
  else
    generate_appgw_cluster_config_file_nossl
    generate_appgw_cluster_config_file_expose_https
  fi
}

function generate_appgw_admin_config_file() {
  if [[ "${enableCustomSSL,,}" == "true" ]];then
    generate_appgw_admin_config_file_ssl
  else
    generate_appgw_admin_config_file_nossl
  fi
}

function output_create_gateway_ssl_k8s_secret(){
  echo "export gateway frontend certificates"
  echo "$appgwFrontendSSLCertData" | base64 -d >${scriptDir}/$appgwFrontCertFileName

  appgwFrontendSSLCertPassin=${appgwFrontendSSLCertPsw}
  if [[ "$appgwCertificateOption" == "${appgwSelfsignedCert}" ]];then
    appgwFrontendSSLCertPassin="" # empty password
  fi

  openssl pkcs12 \
      -in ${scriptDir}/$appgwFrontCertFileName \
      -nocerts \
      -out ${scriptDir}/$appgwFrontCertKeyFileName \
      -passin pass:${appgwFrontendSSLCertPassin} \
      -passout pass:${appgwFrontendSSLCertPsw}

  validate_status "Export key from frontend certificate."

  openssl rsa -in ${scriptDir}/$appgwFrontCertKeyFileName \
    -out ${scriptDir}/$appgwFrontCertKeyDecrytedFileName \
    -passin pass:${appgwFrontendSSLCertPsw}

  validate_status "Decryte private key."

  openssl pkcs12 \
  -in ${scriptDir}/$appgwFrontCertFileName \
  -clcerts \
  -nokeys \
  -out ${scriptDir}/$appgwFrontPublicCertFileName \
  -passin pass:${appgwFrontendSSLCertPassin} \

  validate_status "Export cert from frontend certificate."

  echo "create k8s tsl secret for app gateway frontend ssl certificate"
  kubectl -n ${wlsDomainNS} create secret tls ${appgwFrontendSecretName} \
    --key="${scriptDir}/$appgwFrontCertKeyDecrytedFileName" \
    --cert="${scriptDir}/$appgwFrontPublicCertFileName"
}

function query_admin_target_port() {
  if [[ "${enableCustomSSL,,}" == "true" ]];then
    adminTargetPort=$(kubectl describe service ${svcAdminServer} -n ${wlsDomainNS} | grep 'default-secure' | tr -d -c 0-9)
  else
    adminTargetPort=$(kubectl describe service ${svcAdminServer} -n ${wlsDomainNS} | grep 'default' | tr -d -c 0-9)
  fi

  validate_status "Query admin target port."
  echo "Target port of ${adminServerName}: ${adminTargetPort}"
}

function query_cluster_target_port() {
  if [[ "${enableCustomSSL,,}" == "true" ]];then
    clusterTargetPort=$(kubectl describe service ${svcCluster} -n ${wlsDomainNS} | grep 'default-secure' | tr -d -c 0-9)
  else
    clusterTargetPort=$(kubectl describe service ${svcCluster} -n ${wlsDomainNS} | grep 'default' | tr -d -c 0-9)
  fi

  validate_status "Query cluster 1 target port."
  echo "Target port of ${clusterName}: ${clusterTargetPort}"
}

# Connect to AKS cluster
function connect_aks_cluster() {
  az aks get-credentials --resource-group ${aksClusterRGName} --name ${aksClusterName} --overwrite-existing
}

# create dns alias for lb service
function create_dns_A_record() {
  if [ "${enableCustomDNSAlias,,}" == "true" ]; then
    ipv4Addr=$1
    label=$2
    az network dns record-set a add-record --ipv4-address ${ipv4Addr} \
      --record-set-name ${label} \
      --resource-group ${dnsRGName} \
      --zone-name ${dnsZoneName}
  fi
}

# create dns alias for app gateway
function create_dns_CNAME_record() {
  if [ "${enableCustomDNSAlias,,}" == "true" ]; then

    az network dns record-set cname create \
      -g ${dnsRGName} \
      -z ${dnsZoneName} \
      -n ${dnsClusterLabel}

    az network dns record-set cname set-record \
      -g ${dnsRGName} \
      -z ${dnsZoneName} \
      --cname ${appgwAlias} \
      --record-set-name ${dnsClusterLabel}

    if [[ ${appgwForAdminServer,,} == "true" ]]; then
      az network dns record-set cname create \
        -g ${dnsRGName} \
        -z ${dnsZoneName} \
        -n ${dnsAdminLabel}

      az network dns record-set cname set-record \
        -g ${dnsRGName} \
        -z ${dnsZoneName} \
        --cname ${appgwAlias} \
        --record-set-name ${dnsAdminLabel}
    fi
  fi
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
  ret=$(echo $lbSvcValues | sed "s/\:/\\\"\:\\\"/g" |
    sed "s/{/{\"/g" |
    sed "s/}/\"}/g" |
    sed "s/,/\",\"/g" |
    sed "s/}\",\"{/},{/g" |
    tr -d \(\))

  cat <<EOF >${scriptDir}/lbConfiguration.json
${ret}
EOF

  array=$(jq -r '.[] | "\(.colName),\(.colTarget),\(.colPort)"' ${scriptDir}/lbConfiguration.json)
  for item in $array; do
    # LB config for admin-server
    target=$(cut -d',' -f2 <<<$item)
    if [[ "${target}" == "adminServer" ]]; then
      adminServerLBSVCNamePrefix=$(cut -d',' -f1 <<<$item)
      adminServerLBSVCName="${adminServerLBSVCNamePrefix}-svc-lb-admin"
      adminLBPort=$(cut -d',' -f3 <<<$item)

      generate_admin_lb_definicion

      kubectl apply -f ${scriptDir}/admin-server-lb.yaml
      waitfor_svc_completed ${adminServerLBSVCName}

      adminServerEndpoint=$(kubectl get svc ${adminServerLBSVCName} -n ${wlsDomainNS} -o=jsonpath='{.status.loadBalancer.ingress[0].ip}:{.spec.ports[0].port}')
      adminConsoleEndpoint="${adminServerEndpoint}/console"

      create_dns_A_record "${adminServerEndpoint%%:*}" ${dnsAdminLabel}

      if [ "${enableCustomDNSAlias,,}" == "true" ]; then
        adminConsoleEndpoint="${dnsAdminLabel}.${dnsZoneName}:${adminServerEndpoint#*:}/console"
      fi
    else
      clusterLBSVCNamePrefix=$(cut -d',' -f1 <<<$item)
      clusterLBSVCName="${clusterLBSVCNamePrefix}-svc-lb-cluster"
      clusterLBPort=$(cut -d',' -f3 <<<$item)

      generate_cluster_lb_definicion

      kubectl apply -f ${scriptDir}/cluster-lb.yaml
      waitfor_svc_completed ${clusterLBSVCName}

      clusterEndpoint=$(kubectl get svc ${clusterLBSVCName} -n ${wlsDomainNS} -o=jsonpath='{.status.loadBalancer.ingress[0].ip}:{.spec.ports[0].port}')

      create_dns_A_record "${clusterEndpoint%%:*}" ${dnsClusterLabel}

      if [ "${enableCustomDNSAlias,,}" == "true" ]; then
        clusterEndpoint="${dnsClusterLabel}.${dnsZoneName}:${clusterEndpoint#*:}/"
      fi
    fi
  done
}

# Create network peers for aks and appgw
function network_peers_aks_appgw() {
  # To successfully peer two virtual networks command 'az network vnet peering create' must be called twice with the values
  # for --vnet-name and --remote-vnet reversed.
  aksMCRGName=$(az aks show -n $aksClusterName -g $aksClusterRGName -o tsv --query "nodeResourceGroup")
  ret=$(az group exists ${aksMCRGName})
  if [ "${ret,,}" == "false" ]; then
    echo_stderr "AKS namaged resource group ${aksMCRGName} does not exist."
    exit 1
  fi

  aksNetWorkId=$(az resource list -g ${aksMCRGName} --resource-type Microsoft.Network/virtualNetworks -o tsv --query '[*].id')
  aksNetworkName=$(az resource list -g ${aksMCRGName} --resource-type Microsoft.Network/virtualNetworks -o tsv --query '[*].name')
  az network vnet peering create \
    --name aks-appgw-peer \
    --remote-vnet ${aksNetWorkId} \
    --resource-group ${curRGName} \
    --vnet-name ${vnetName} \
    --allow-vnet-access
  validate_status "Create network peers for $aksNetWorkId and ${vnetName}."

  appgwNetworkId=$(az resource list -g ${curRGName} --name ${vnetName} -o tsv --query '[*].id')
  az network vnet peering create \
    --name aks-appgw-peer \
    --remote-vnet ${appgwNetworkId} \
    --resource-group ${aksMCRGName} \
    --vnet-name ${aksNetworkName} \
    --allow-vnet-access

  validate_status "Create network peers for $aksNetWorkId and ${vnetName}."

  # For Kbectl network plugin: https://azure.github.io/application-gateway-kubernetes-ingress/how-tos/networking/#with-kubenet
  # find route table used by aks cluster
  routeTableId=$(az network route-table list -g $aksMCRGName --query "[].id | [0]" -o tsv)

  # get the application gateway's subnet
  appGatewaySubnetId=$(az network application-gateway show -n $appgwName -g $curRGName -o tsv --query "gatewayIpConfigurations[0].subnet.id")

  # associate the route table to Application Gateway's subnet
  az network vnet subnet update \
    --ids $appGatewaySubnetId \
    --route-table $routeTableId

  validate_status "Associate the route table ${routeTableId} to Application Gateway's subnet ${appGatewaySubnetId}"
}



function create_appgw_ingress() {
  if [[ "${enableAppGWIngress,,}" != "true" ]]; then
    return
  fi

  query_admin_target_port
  query_cluster_target_port
  network_peers_aks_appgw

  # create sa and bind cluster-admin role
  kubectl apply -f ${scriptDir}/appgw-ingress-clusterAdmin-roleBinding.yaml

  # Keep the aad pod identity controller installation, may be used for CNI network usage
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

  # generate helm config
  customAppgwHelmConfig=${scriptDir}/appgw-helm-config.yaml
  cp ${scriptDir}/appgw-helm-config.yaml.template ${customAppgwHelmConfig}
  subID=${subID#*\/subscriptions\/}
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
    --version ${azureAppgwIngressVersion}

  validate_status "Install app gateway ingress controller."

  attempts=0
  podState="running"
  while [ ! "$podState" == "completed" ] && [ $attempts -lt ${perfPodAttemps} ]; do
    podState="completed"
    attempts=$((attempts + 1))
    echo Waiting for Pod running...${attempts}
    sleep ${perfRetryInterval}

    ret=$(kubectl get pod | grep "ingress-azure")
    if [ -z "${ret}" ]; then
      podState="running"

      if [ $attempts -ge ${perfPodAttemps} ]; then
        echo_stderr "Failed to install app gateway ingress controller."
        exit 1
      fi
    fi
  done

  # create tsl secret
  output_create_gateway_ssl_k8s_secret

  
  if [[ "${enableCustomSSL,,}" == "true" ]];then
    # create backend tls secret
    rootcertPath=${scriptDir}/root.cert
    kubectl cp -n ${wlsDomainNS} ${wlsDomainUID}-${adminServerName}:${appgwBackendCertPath} ${rootcertPath}
    validate_status "Copy public key from fileshare."

    az network application-gateway root-cert create \
      --gateway-name $appgwName  \
      --resource-group $curRGName \
      --name ${appgwBackendSecretName} \
      --cert-file ${rootcertPath}
  fi

  # generate ingress svc config for cluster  
  generate_appgw_cluster_config_file
  kubectl apply -f ${clusterAppgwIngressYamlPath}
  validate_status "Create appgw ingress svc."
  waitfor_svc_completed ${clusterIngressName}
  # expose https if e2e ssl is not set up.
  if [[ "${enableCustomSSL,,}" != "true" ]];then
    kubectl apply -f ${clusterAppgwIngressHttpsYamlPath}
    validate_status "Create appgw ingress https svc."
    waitfor_svc_completed ${clusterIngressHttpsName}
  fi

  if [[ ${appgwForAdminServer,,} == "true" ]]; then
    generate_appgw_admin_config_file
    kubectl apply -f ${adminAppgwIngressYamlPath}
    validate_status "Create appgw ingress svc."
    waitfor_svc_completed ${adminIngressName}
  fi

  create_dns_CNAME_record
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
export appgwForAdminServer=${12}
export enableCustomDNSAlias=${13}
export dnsRGName=${14}
export dnsZoneName=${15}
export dnsAdminLabel=${16}
export dnsClusterLabel=${17}
export appgwAlias=${18}
export enableInternalLB=${19}
export appgwFrontendSSLCertData=${20}
export appgwFrontendSSLCertPsw=${21}
export appgwCertificateOption=${22}
export enableCustomSSL=${23}

export adminServerName="admin-server"
export adminConsoleEndpoint="null"
export appgwIngressHelmRepo="https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/"
export appgwFrontCertFileName="appgw-frontend-cert.pfx"
export appgwFrontCertKeyDecrytedFileName="appgw-frontend-cert.key"
export appgwFrontCertKeyFileName="appgw-frontend-cert-decryted.key"
export appgwFrontPublicCertFileName="appgw-frontend-cert.crt"
export appgwFrontendSecretName="frontend-tls"
export appgwBackendSecretName="backend-tls"
export appgwSelfsignedCert="generateCert"
export azureAppgwIngressVersion="1.4.0"
export clusterName="cluster-1"
export clusterEndpoint="null"
export httpsListenerName="myHttpsListenerName$(date +%s)"
export httpsRuleName="myHttpsRule$(date +%s)"
export perfRetryInterval=30 # seconds
export perfPodAttemps=5
export perfSVCAttemps=10
export sharedPath="/shared"
export svcAdminServer="${wlsDomainUID}-${adminServerName}"
export svcCluster="${wlsDomainUID}-cluster-${clusterName}"
export wlsDomainNS="${wlsDomainUID}-ns"
export appgwBackendCertPath="${sharedPath}/security/root.cert"

echo $lbSvcValues

validate_input

install_utilities

connect_aks_cluster

create_svc_lb

create_appgw_ingress

output_result
