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

function create_svc_lb() {
  adminTargetPort=$(kubectl describe service ${svcAdminServer} -n ${wlsDomainNS} | grep 'TargetPort:' | tr -d -c 0-9)
  echo "Target port of ${adminServerName}: ${adminTargetPort}"
  clusterTargetPort=$(kubectl describe service ${svcCluster} -n ${wlsDomainNS} | grep 'TargetPort:' | tr -d -c 0-9)
  echo "Target port of ${clusterName}: ${adminTargetPort}"

  # Parse lb svc input values

  generate_admin_lb_definicion
  generate_cluster_lb_definicion



}

# Main script
export script="${BASH_SOURCE[0]}"
export scriptDir="$(cd "$(dirname "${script}")" && pwd)"

export aksClusterRGName=$1
export aksClusterName=$2
export wlsDomainName=$3
export wlsDomainUID=$4
export lbSvcValues=$5

export adminServerName="admin-server"
export clusterName="cluster-1"
export svcAdminServer="${wlsDomainUID}-${adminServerName}"
export svcCluster="${wlsDomainUID}-cluster-${clusterName}"
export wlsDomainNS="${wlsDomainUID}-ns"

echo $lbSvcValues

cat <<EOF >lbConfiguration.json
${lbSvcValues}
EOF

array=$(jq  -r '.[] | "\(.colName),\(.colTarget),\(.colPort)"' lbConfiguration.json)
for item in $array; do echo $item;done

validate_input

install_utilities

connect_aks_cluster

create_svc_lb

exit 1