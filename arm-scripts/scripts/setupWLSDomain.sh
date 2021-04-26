echo "Script starts"
#https://github.com/MicrosoftDocs/azure-docs/issues/43947
# https://hub.docker.com/_/docker

#Function to output message to StdErr
function echo_stderr() {
    echo "$@" >&2
}

#Function to display usage message
function usage() {
    echo_stderr ""
}

# Validate teminal status with $?, exit if errors happen.
function validate_status() {
    echo "$@" >&2

    if [ $? == 1 ]; then
        echo "Errors happen, exit 1."
        exit 1
    fi
}

# Install docker, kubectl, helm and java
function install_utilities() {
    if [ -d "apps" ]; then
        rm apps -f -r
    fi

    mkdir apps
    cd apps

    # Install docker
    sudo apt-get update
    sudo apt-get -q install apt-transport-https
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
    "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get -q install docker-ce docker-ce-cli containerd.io

    echo "docker Version"
    docker --version
    validate_status "Check status of docker."

    # Install az cli
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    echo "az cli version"
    az --version
    validate_status "Check status of az cli."

    # Install kubectl and connect to the AKS cluster
    az aks install-cli
    echo "kubectl version"
    kubectl version
    validate_status "Check status of kubectl."

    # Install helm
    curl -LO https://get.helm.sh/helm-v3.5.4-linux-amd64.tar.gz
    tar -zxvf helm-v3.5.4-linux-amd64.tar.gz
    sudo mv linux-amd64/helm /usr/local/bin/helm
    echo "helm version"
    helm version
    validate_status "Check status of helm."

    # Install Zulu JDK 8
    sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9
    sudo apt-add-repository "deb http://repos.azul.com/azure-only/zulu/apt stable main"
    sudo apt-get -q update
    sudo apt-get -q -y install zulu-8-azure-jdk
    echo "java version"
    java -version
    validate_status "Check status of Zulu JDK 8."

    echo "git version"
    git --version
    validate_status "Check status of git."

    sudo apt install zip
    zip --help
    validate_status "Check status of zip."

    sudo apt install unzip
    echo "unzip version"
    unzip --help
    validate_status "Check status of unzip."
}

function get_wls_image_from_ocr() {
    docker logout
    docker login ${ocrLoginServer} -u ${ocrSSOUser} -p ${ocrSSOPSW}
    wlsImagePath=container-registry.oracle.com/middleware/weblogic:${wlsImageTag}
    echo "Start to pull image ${wlsImagePath}"
    docker pull -q ${wlsImagePath}
    validate_status "Finish pulling image from OCR."
}

function connect_aks_cluster() {
    az aks get-credentials --resource-group ${aksClusterRGName} --name ${aksClusterName}
}

function install_wls_operator() {
    kubectl create namespace ${wlsOptNameSpace}
    kubectl -n ${wlsOptNameSpace} create serviceaccount ${wlsOptSA}

    helm repo add ${wlsOptRelease} ${wlsOptHelmChart} --force-update
    helm repo list
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
    azureACRUserName=$(az acr credential show -n $acrName --query 'username' -o tsv)
    azureACRPassword=$(az acr credential show -n $acrName --query 'passwords[0].value' -o tsv)
}

function build_docker_image() {
    chmod ugo+x ${scriptDir}/buildWLSDockerImage.sh
    bash ${scriptDir}/buildWLSDockerImage.sh ${wlsImagePath} ${azureACRServer} ${azureACRUserName} ${azureACRPassword} ${newImageTag}
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
    cp ${scriptDir}/domain.yaml ${customDomainYaml}
    sed -i -e "s:@WLS_DOMAIN_UID@:${wlsDomainUID}:g" ${customDomainYaml}
    sed -i -e "s:@WLS_IMAGE_PATH_ACR@:$azureACRServer/aks-wls-images\:${newImageTag}:g" ${customDomainYaml}
    sed -i -e "s:@RESOURCE_CPU@:${wlsCPU}:g" ${customDomainYaml}
    sed -i -e "s:@RESOURCE_MEMORY@:${wlsMemory}:g" ${customDomainYaml}

    wait_for_domain_completed
}

function wait_for_domain_completed() {
    attempts=0
    svcState="running"
    while [ ! "$svcState" == "completed" ] && [ ! $attempts -eq 30 ]; do
        svcState="completed"
        attempts=$((attempts + 1))
        echo Waiting for job completed...${attempts}
        sleep 120

        # If the job is completed, there should have the following services created,
        #    ${domainUID}-${adminServerName}, e.g. domain1-admin-server
        #    ${domainUID}-${adminServerName}-ext, e.g. domain1-admin-server-ext
        adminServiceCount=`kubectl get svc | grep -c "${wlsDomainUID}-${adminServerName}"`
        if [ ${adminServiceCount} -lt 2 ]; then svcState="running"; fi

        # If the job is completed, there should have the following services created, .assuming initialManagedServerReplicas=2
        #    ${domainUID}-${managedServerNameBase}1, e.g. domain1-managed-server1
        #    ${domainUID}-${managedServerNameBase}2, e.g. domain1-managed-server2
        managedServiceCount=`kubectl get svc | grep -c "${wlsDomainUID}-${managedServerPrefix}"`
        if [ ${managedServiceCount} -lt ${appReplicas} ]; then svcState="running"; fi

        # If the job is completed, there should have no service in pending status.
        pendingCount=`kubectl get pod | grep -c "pending"`
        if [ ${pendingCount} -ne 0 ]; then svcState="running"; fi

        # If the job is completed, there should have the following pods running
        #    ${domainUID}-${adminServerName}, e.g. domain1-admin-server
        #    ${domainUID}-${managedServerNameBase}1, e.g. domain1-managed-server1 
        #    to
        #    ${domainUID}-${managedServerNameBase}n, e.g. domain1-managed-servern, n = initialManagedServerReplicas
        runningPodCount=`kubectl get pods | grep "${wlsDomainUID}" | grep -c "Running"`
        if [[ $runningPodCount -le ${appReplicas} ]]; then svcState="running"; fi
    done

    # If all the services are completed, print service details
    # Otherwise, ask the user to refer to document for troubleshooting
    if [ "$svcState" == "completed" ];
    then 
        kubectl get pods
        kubectl get svc
    else
        echo It takes a little long to create domain, please refer to http://oracle.github.io/weblogic-kubernetes-operator/samples/simple/azure-kubernetes-service/#troubleshooting
        exit 1
    fi
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
export wlsDomainUID=$7
export wlsUserName=$8
export wlsPassword=$9
export wdtRuntimePassword=${10}
export wlsCPU=${11}
export wlsMemory=${12}
export managedServerPrefix=${13}
export appReplicas=${14}

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

# install_utilities

get_wls_image_from_ocr

query_acr_credentials

build_docker_image

connect_aks_cluster

install_wls_operator

setup_wls_domain
