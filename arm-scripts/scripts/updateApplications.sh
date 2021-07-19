# Copyright (c) 2019, 2020, Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

echo "Script ${0} starts"

# Query ACR login server, username, password
function query_acr_credentials() {
    echo "query credentials of ACR ${acrName}"
    azureACRServer=$(az acr show -n $acrName --query 'loginServer' -o tsv)
    azureACRUserName=$(az acr credential show -n $acrName --query 'username' -o tsv)
    azureACRPassword=$(az acr credential show -n $acrName --query 'passwords[0].value' -o tsv)
}

function build_docker_image() {
    echo "build a new image including the new applications"
    chmod ugo+x $scriptDir/createVMAndBuildImage.sh
    bash $scriptDir/createVMAndBuildImage.sh \
        currentResourceGroup \
        wlsImageTag \
        azureACRServer \
        azureACRUserName \
        azureACRPassword \
        newImageTag \
        appPackageUrls \
        ocrSSOUser \
        ocrSSOPSW \
        wlsClusterSize \
        enableCustomSSL \
        scriptURL
}

function apply_new_image() {
    acrImagePath="${azureACRServer}/aks-wls-images:${newImageTag}"
    restartVersion=$(kubectl -n ${wlsDomainNS} get domain ${wlsDomainUID} '-o=jsonpath={.spec.restartVersion}')
    # increase restart version
    restartVersion=$((restartVersion + 1))
    kubectl -n ${wlsDomainNS} patch domain ${wlsDomainUID} \
        --type=json \
        '-p=[{"op": "replace", "path": "/spec/restartVersion", "value": "'${restartVersion}'" }, {"op": "replace", "path": "/spec/image", "value": "'${acrImagePath}'" }]'
}

function wait_for_pod_completed() {
    # Make sure all of the pods are running.
    replicas=$(kubectl -n ${wlsDomainNS} get domain ${wlsDomainUID} -o json 
        | jq '. | .spec.clusters[] | .replicas')
    readyPodNum=$(kubectl get pods -n ${wlsDomainNS} -o json  
        | jq '.items[] | .status.phase' 
        | grep -c "Running")

    attempt=0
    while [[ ${readyPodNum} -le  ${replicas} && attempt -le ${checkPodStatusMaxAttemps} ]];do
        sleep ${checkPodStatusInterval}
        readyPodNum=$(kubectl get pods -n ${wlsDomainNS} -o json  
        | jq '.items[] | .status.phase' 
        | grep -c "Running")

        attempt=$((attempt+1))
    done

    if [ ${attempt} -gt ${checkPodStatusMaxAttemps} ];then
        echo "It takes too long to wait for all the pods are running, please refer to http://oracle.github.io/weblogic-kubernetes-operator/samples/simple/azure-kubernetes-service/#troubleshooting"
        exit 1
    fi
}

function wait_for_image_update_completed() {
    # Make sure all of the pods are updated with new image.
    # Assumption: we have only one cluster currently.
    replicas=$(kubectl -n ${wlsDomainNS} get domain ${wlsDomainUID} -o json 
        | jq '. | .spec.clusters[] | .replicas')
    updatedPodNum=$(kubectl get pods -n ${wlsDomainNS} -o json 
        | jq '.items[] | .spec | .containers[] | select(.name == "weblogic-server") | .image'
        | grep -c "${acrImagePath}")

    attempt=0
    while [[ ${updatedPodNum} -le  ${replicas} && attempt -le ${checkPodStatusMaxAttemps} ]];do
        sleep ${checkPodStatusInterval}
        updatedPodNum=$(kubectl get pods -n ${wlsDomainNS} -o json 
        | jq '.items[] | .spec | .containers[] | select(.name == "weblogic-server") | .image'
        | grep -c "${acrImagePath}")

        attempt=$((attempt+1))
    done

    if [ ${attempt} -gt ${checkPodStatusMaxAttemps} ];then
        echo "Failed to update with image ${acrImagePath} to all weblogic server pods. "
        exit 1
    fi
}

# Main script
export script="${BASH_SOURCE[0]}"
export scriptDir="$(cd "$(dirname "${script}")" && pwd)"

source ${scriptDir}/common.sh
source ${scriptDir}/utility.sh

# Shell Global settings
set -e #Exit immediately if a command exits with a non-zero status.

export ocrSSOUser=$1
export ocrSSOPSW=$2
export aksClusterRGName=$3
export aksClusterName=$4
export wlsImageTag=$5
export acrName=$6
export wlsDomainName=$7
export wlsDomainUID=$8
export wlsClusterSize=$9
export enableCustomSSL=${10}
export currentResourceGroup=${11}
export appPackageUrls=${12}
export scriptURL=${13}

export newImageTag=$(date +%s)
export wlsDomainNS="${wlsDomainUID}-ns"

install_kubectl

build_docker_image

apply_new_image

wait_for_image_update_completed

wait_for_pod_completed
