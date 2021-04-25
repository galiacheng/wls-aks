echo "Script starts"

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
    apk update
    apk add gettext
    apk add docker-cli
    echo "docker Version"
    docker --version
    validate_status "Check status of docker."

    # Install kubectl and connect to the AKS cluster
    az aks install-cli
    echo "kubectl version"
    kubectl version
    validate_status "Check status of kubectl."

    # Install helm
    curl -LO https://get.helm.sh/helm-v3.5.4-linux-amd64.tar.gz
    tar -zxvf helm-v3.5.4-linux-amd64.tar.gz
    mv linux-amd64/helm /usr/local/bin/helm
    echo "helm version"
    helm version
    validate_status "Check status of helm."

    # Install Zulu JDK 8
    wget https://cdn.azul.com/public_keys/alpine-signing@azul.com-5d5dc44c.rsa.pub
    cp alpine-signing@azul.com-5d5dc44c.rsa.pub /etc/apk/keys/
    echo "https://repos.azul.com/zulu/alpine" >>/etc/apk/repositories
    apk update
    apk add zulu8-jdk
    echo "java version"
    java -version
    validate_status "Check status of Zulu JDK 8."

    echo "az cli version"
    az --version
    validate_status "Check status of az cli."

    echo "git version"
    git --version
    validate_status "Check status of git."

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

function install_wls_operator() {
    kubectl create namespace ${wlsOptNameSpace}
    kubectl -n ${wlsOptNameSpace} create serviceaccount  ${wlsOptSA}

    helm repo add ${wlsOptRelease} ${wlsOptHelmChart} --force-update
    helm list
    helm install ${wlsOptRelease} kubernetes/charts/weblogic-operator \
    --namespace ${wlsOptNameSpace} \
    --set serviceAccount=${wlsOptSA} \
    --set "enableClusterRoleBinding=true" \
    --set "domainNamespaceSelectionStrategy=LabelSelector" \
    --set "domainNamespaceLabelSelector=weblogic-operator\=enabled" \
    --wait
}

# Main script

export ocrSSOUser=$1
export ocrSSOPSW=$2
export aksClusterRGName=$3
export aksClusterName=$4
export wlsImageTag=$5

export ocrLoginServer="container-registry.oracle.com"
export wlsOptHelmChart="https://oracle.github.io/weblogic-kubernetes-operator/charts"
export wlsOptNameSpace="weblogic-operator-ns"
export wlsOptRelease="weblogic-operator"
export wlsOptSA="weblogic-operator-sa"

install_utilities
get_wls_image_from_ocr
install_wls_operator
