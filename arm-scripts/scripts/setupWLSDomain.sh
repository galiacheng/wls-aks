echo "Script starts"

#Function to output message to StdErr
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
    echo_stdout ""
}

# Validate teminal status with $?, exit if errors happen.
function validate_status() {
    if [ $? == 1 ]; then
        echo_stderr "$@"
        echo_stderr "Errors happen, exit 1."
        exit 1
    else
        echo_stdout "$@"
    fi
}

# Install docker, kubectl, helm and java
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

    # Install helm
    curl -LO https://get.helm.sh/helm-v3.5.4-linux-amd64.tar.gz
    tar -zxvf helm-v3.5.4-linux-amd64.tar.gz
    chmod +x linux-amd64/helm
    mv linux-amd64/helm /usr/local/bin/helm
    echo "helm version"
    ret=$(helm version)
    validate_status ${ret}

    echo "az cli version"
    ret=$(az --version)
    validate_status ${ret}
    ret=$(az account show)
    echo $ret >>stdout
    if [ -n `echo ${ret} | grep "systemAssignedIdentity"` ]; then
        echo_stderr "Make sure you are using user assigned identity."
        exit 1
    fi
}

function connect_aks_cluster() {
    az aks get-credentials --resource-group ${aksClusterRGName} --name ${aksClusterName} --overwrite-existing
}

function install_wls_operator() {
    kubectl create namespace ${wlsOptNameSpace}
    kubectl -n ${wlsOptNameSpace} create serviceaccount ${wlsOptSA}

    helm repo add ${wlsOptRelease} ${wlsOptHelmChart} --force-update
    ret=$(helm repo list)
    validate_status ${ret}
    helm install ${wlsOptRelease} weblogic-operator/weblogic-operator \
    --namespace ${wlsOptNameSpace} \
    --set serviceAccount=${wlsOptSA} \
    --set "enableClusterRoleBinding=true" \
    --set "domainNamespaceSelectionStrategy=LabelSelector" \
    --set "domainNamespaceLabelSelector=weblogic-operator\=enabled" \
    --wait
}

function query_acr_credentials() {
    azureACRServer=$(az acr show -n $acrName --query 'loginServer' -o tsv)
    validate_status ${azureACRServer}
    azureACRUserName=$(az acr credential show -n $acrName --query 'username' -o tsv)
    azureACRPassword=$(az acr credential show -n $acrName --query 'passwords[0].value' -o tsv)
    validate_status "Query ACR credentials."
}

function build_docker_image() {
    # Create vm to build docker image
    vmName="VM-UBUNTU"

    az vm create \
    --resource-group ${currentResourceGroup} \
    --name ${vmName} \
    --image "Canonical:UbuntuServer:18.04-LTS:latest" \
    --admin-username azureuser \
    --generate-ssh-keys \
    --nsg-rule NONE \
    --enable-agent true \
    --enable-auto-update false \
    --verbose

    validate_status "Check status of VM machine to build docker image."

    wlsImagePath="${ocrLoginServer}/middleware/weblogic:${wlsImageTag}"
    az vm extension set --name CustomScript \
    --extension-instance-name wls-image-script \
    --resource-group ${currentResourceGroup} \
    --vm-name ${vmName} \
    --publisher Microsoft.Azure.Extensions \
    --version 2.0 \
    --settings "{ \"fileUris\": [\"${scriptURL}/model.yaml\",\"${scriptURL}/model.properties\",\"${scriptURL}/buildWLSDockerImage.sh\"]}" \
    --protected-settings "{\"commandToExecute\":\"bash buildWLSDockerImage.sh ${wlsImagePath} ${azureACRServer} ${azureACRUserName} ${azureACRPassword} ${newImageTag} ${appPackageUrl} ${ocrSSOUser} ${ocrSSOPSW}\"}"

    # If error fires, keep vm resource and exit.
    validate_status "Check status of buiding WLS domain image."

    #Validate image from ACR
    az acr repository show -n ${acrName} --image aks-wls-images:${newImageTag}
    validate_status "Check if new image aks-wls-images:${newImageTag} is pushed to acr."
}

function setup_wls_domain() {
    kubectl create namespace ${wlsDomainNS}
    kubectl label namespace ${wlsDomainNS} weblogic-operator=enabled

    kubectl -n ${wlsDomainNS} create secret generic ${kubectlWLSCredentials} \
    --from-literal=username=${wlsUserName} --from-literal=password=${wlsPassword}
    kubectl -n ${wlsDomainNS} label secret ${kubectlWLSCredentials} weblogic.domainUID=${wlsDomainUID}

    kubectl -n ${wlsDomainNS} create secret generic ${wlsDomainUID}-runtime-encryption-secret \
    --from-literal=password=${wdtRuntimePassword}
    kubectl -n ${wlsDomainNS} label secret ${wlsDomainUID}-runtime-encryption-secret weblogic.domainUID=${wlsDomainUID}

    kubectl create secret docker-registry ${kubectlSecretForACR} \
    --docker-server=${azureACRServer} \
    --docker-username=${azureACRUserName} \
    --docker-password=${azureACRPassword} \
    -n ${wlsDomainNS}

    # generate domain yaml
    customDomainYaml=${scriptDir}/custom-domain.yaml
    cp ${scriptDir}/domain.yaml.template ${customDomainYaml}
    sed -i -e "s:@WLS_DOMAIN_UID@:${wlsDomainUID}:g" ${customDomainYaml}
    sed -i -e "s:@WLS_IMAGE_PATH_ACR@:${azureACRServer}/aks-wls-images\:${newImageTag}:g" ${customDomainYaml}
    sed -i -e "s:@RESOURCE_CPU@:${wlsCPU}:g" ${customDomainYaml}
    sed -i -e "s:@RESOURCE_MEMORY@:${wlsMemory}:g" ${customDomainYaml}
    sed -i -e "s:@DOMAIN_NAME@:${wlsDomainName}:g" ${customDomainYaml}
    sed -i -e "s:@MANAGED_SERVER_PREFIX@:${managedServerPrefix}:g" ${customDomainYaml}
    sed -i -e "s:@WLS_CLUSTER_REPLICAS@:${appReplicas}:g" ${customDomainYaml}

    kubectl apply -f ${customDomainYaml}

    wait_for_domain_completed
}

function wait_for_domain_completed() {
    attempts=0
    svcState="running"
    while [ ! "$svcState" == "completed" ] && [ $attempts -lt 3 ]; do
        svcState="completed"
        attempts=$((attempts + 1))
        echo Waiting for job completed...${attempts}
        sleep 2m

        # If the job is completed, there should have the following services created,
        #    ${domainUID}-${adminServerName}, e.g. domain1-admin-server
        #    ${domainUID}-${adminServerName}-ext, e.g. domain1-admin-server-ext
        adminServiceCount=$(kubectl -n ${wlsDomainNS} get svc | grep -c "${wlsDomainUID}-${adminServerName}")
        if [ ${adminServiceCount} -lt 2 ]; then svcState="running"; fi

        # If the job is completed, there should have the following services created, .assuming initialManagedServerReplicas=2
        #    ${domainUID}-${managedServerNameBase}1, e.g. domain1-managed-server1
        #    ${domainUID}-${managedServerNameBase}2, e.g. domain1-managed-server2
        managedServiceCount=$(kubectl -n ${wlsDomainNS} get svc | grep -c "${wlsDomainUID}-${managedServerPrefix}")
        if [ ${managedServiceCount} -lt ${appReplicas} ]; then svcState="running"; fi

        # If the job is completed, there should have no service in pending status.
        pendingCount=$(kubectl -n ${wlsDomainNS} get pod | grep -c "pending")
        if [ ${pendingCount} -ne 0 ]; then svcState="running"; fi

        # If the job is completed, there should have the following pods running
        #    ${domainUID}-${adminServerName}, e.g. domain1-admin-server
        #    ${domainUID}-${managedServerNameBase}1, e.g. domain1-managed-server1
        #    to
        #    ${domainUID}-${managedServerNameBase}n, e.g. domain1-managed-servern, n = initialManagedServerReplicas
        runningPodCount=$(kubectl -n ${wlsDomainNS} get pods | grep "${wlsDomainUID}" | grep -c "Running")
        if [[ $runningPodCount -le ${appReplicas} ]]; then svcState="running"; fi
    done

    # If all the services are completed, print service details
    # Otherwise, ask the user to refer to document for troubleshooting
    if [ "$svcState" == "completed" ]; then
        kubectl -n ${wlsDomainNS} get pods
        kubectl -n ${wlsDomainNS} get svc
    else
        echo It takes a little long to create domain, please refer to http://oracle.github.io/weblogic-kubernetes-operator/samples/simple/azure-kubernetes-service/#troubleshooting
        exit 1
    fi
}

function cleanup() {
    #Remove VM resources
    az extension add --name resource-graph
    # query vm id
    vmId=$(az graph query -q "Resources \
| where type =~ 'microsoft.compute/virtualmachines' \
| where name=~ '${vmName}' \
| where resourceGroup  =~ '${currentResourceGroup}' \
| project vmid = id" -o tsv)

    # query nic id
    nicId=$(az graph query -q "Resources \
| where type =~ 'microsoft.compute/virtualmachines' \
| where name=~ '${vmName}' \
| where resourceGroup  =~ '${currentResourceGroup}' \
| extend nics=array_length(properties.networkProfile.networkInterfaces) \
| mv-expand nic=properties.networkProfile.networkInterfaces \
| where nics == 1 or nic.properties.primary =~ 'true' or isempty(nic) \
| project nicId = tostring(nic.id)" -o tsv)

    # query ip id
    ipId=$(az graph query -q "Resources \
| where type =~ 'microsoft.network/networkinterfaces' \
| where id=~ '${nicId}' \
| extend ipConfigsCount=array_length(properties.ipConfigurations) \
| mv-expand ipconfig=properties.ipConfigurations \
| where ipConfigsCount == 1 or ipconfig.properties.primary =~ 'true' \
| project  publicIpId = tostring(ipconfig.properties.publicIPAddress.id)" -o tsv)

    # query os disk id
    osDiskId=$(az graph query -q "Resources \
| where type =~ 'microsoft.compute/virtualmachines' \
| where name=~ '${vmName}' \
| where resourceGroup  =~ '${currentResourceGroup}' \
| project osDiskId = tostring(properties.storageProfile.osDisk.managedDisk.id)" -o tsv)

    # query vnet id
    vnetId=$(az graph query -q "Resources \
| where type =~ 'Microsoft.Network/virtualNetworks' \
| where name=~ '${vmName}VNET' \
| where resourceGroup  =~ '${currentResourceGroup}' \
| project vNetId = id" -o tsv)

    # query nsg id
    nsgId=$(az graph query -q "Resources \
| where type =~ 'Microsoft.Network/networkSecurityGroups' \
| where name=~ '${vmName}NSG' \
| where resourceGroup  =~ '${currentResourceGroup}' \
| project nsgId = id" -o tsv)

    vmResourceIdS=$(echo ${vmId} ${nicId} ${ipId} ${osDiskId} ${vnetId} ${nsgId})
    az resource delete --verbose --ids ${vmResourceIdS}
}

# Main script
export script="${BASH_SOURCE[0]}"
export scriptDir="$(cd "$(dirname "${script}")" && pwd)"

export ocrSSOUser=$1
export ocrSSOPSW=$2
export aksClusterRGName=$3
export aksClusterName=$4
export wlsImageTag=$5
export acrName=$6
export wlsDomainName=$7
export wlsDomainUID=$8
export wlsUserName=$9
export wlsPassword=${10}
export wdtRuntimePassword=${11}
export wlsCPU=${12}
export wlsMemory=${13}
export managedServerPrefix=${14}
export appReplicas=${15}
export appPackageUrl=${16}
export currentResourceGroup=${17}
export scriptURL=${18}

export adminServerName="admin-server"
export ocrLoginServer="container-registry.oracle.com"
export kubectlSecretForACR="regsecret"
export kubectlWLSCredentials="${wlsDomainUID}-weblogic-credentials"
export newImageTag=$(date +%s)
export wlsDomainNS="${wlsDomainUID}-ns"
export wlsOptHelmChart="https://oracle.github.io/weblogic-kubernetes-operator/charts"
export wlsOptNameSpace="weblogic-operator-ns"
export wlsOptRelease="weblogic-operator"
export wlsOptSA="weblogic-operator-sa"

install_utilities

query_acr_credentials

build_docker_image

connect_aks_cluster

install_wls_operator

setup_wls_domain

cleanup
