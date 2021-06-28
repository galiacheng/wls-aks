# Copyright (c) 2019, 2020, Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

echo "Script  ${0} starts"

#Function to output message to StdErr
function echo_stderr() {
    echo "$@" >&2
}

#Function to display usage message
function usage() {
    echo_stdout "./buildWLSDockerImage.sh <wlsImagePath> <azureACRServer> <azureACRUserName> <azureACRPassword> <imageTag> <appPackageUrls> <ocrSSOUser> <ocrSSOPSW> <wlsClusterSize>"
    if [ $1 -eq 1 ]; then
        exit 1
    fi
}

# Validate teminal status with $?, exit if errors happen.
function validate_status() {
    if [ $? == 1 ]; then
        echo "$@" >&2
        echo "Errors happen, exit 1."
        exit 1
    fi
}

function validate_inputs() {
    if [ -z "$wlsImagePath" ]; then
        echo_stderr "wlsImagePath is required. "
        usage 1
    fi

    if [ -z "$azureACRServer" ]; then
        echo_stderr "azureACRServer is required. "
        usage 1
    fi

    if [ -z "$azureACRUserName" ]; then
        echo_stderr "azureACRUserName is required. "
        usage 1
    fi

    if [ -z "$azureACRPassword" ]; then
        echo_stderr "azureACRPassword is required. "
        usage 1
    fi

    if [ -z "$imageTag" ]; then
        echo_stderr "imageTag is required. "
        usage 1
    fi

    if [ -z "$appPackageUrls" ]; then
        echo_stderr "appPackageUrls is required. "
        usage 1
    fi

    if [ -z "$ocrSSOUser" ]; then
        echo_stderr "ocrSSOUser is required. "
        usage 1
    fi

    if [ -z "$ocrSSOPSW" ]; then
        echo_stderr "ocrSSOPSW is required. "
        usage 1
    fi

    if [ -z "$wlsClusterSize" ]; then
        echo_stderr "wlsClusterSize is required. "
        usage 1
    fi
}

function initialize() {
    if [ -d "model-images" ]; then
        rm model-images -f -r
    fi

    mkdir model-images
    cd model-images

    # Create Model directory
    mkdir wlsdeploy
    mkdir wlsdeploy/config
    mkdir wlsdeploy/applications
    # Store certificates
    mkdir wlsdeploy/servers
}

# Install docker, zip, unzip and java
# Download WebLogic Tools
function install_utilities() {
    # Install docker
    sudo apt-get -q update
    sudo apt-get -y -q install apt-transport-https
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get -q update
    sudo apt-get -y -q install docker-ce docker-ce-cli containerd.io

    echo "docker version"
    sudo docker --version
    validate_status "Check status of docker."
    sudo systemctl start docker

    # Install Microsoft OpenJDK
    wget https://packages.microsoft.com/config/ubuntu/18.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
    sudo dpkg -i packages-microsoft-prod.deb
    sudo apt -q update
    sudo apt -y -q install msopenjdk-11

    echo "java version"
    java -version
    validate_status "Check status of Zulu JDK 8."

    export JAVA_HOME=/usr/lib/jvm/msopenjdk-11-amd64
    if [ ! -d "${JAVA_HOME}" ]; then
        echo "Java home ${JAVA_HOME} does not exist"
        exit 1
    fi

    sudo apt -y -q install zip
    zip --help
    validate_status "Check status of zip."

    sudo apt -y -q install unzip
    echo "unzip version"
    unzip --help
    validate_status "Check status of unzip."

    # Download weblogic tools
    curl -m 120 -fL ${wdtDownloadURL} -o weblogic-deploy.zip
    validate_status "Check status of weblogic-deploy.zip."

    curl -m 120 -fL ${witDownloadURL} -o imagetool.zip
    validate_status "Check status of imagetool.zip."
}

# Login in OCR
# Pull weblogic image
function get_wls_image_from_ocr() {
    sudo docker logout
    sudo docker login ${ocrLoginServer} -u ${ocrSSOUser} -p ${ocrSSOPSW}
    echo "Start to pull image ${wlsImagePath}"
    sudo docker pull -q ${wlsImagePath}
    validate_status "Finish pulling image from OCR."
}

# Generate model configurations
function prepare_wls_models() {
    # Create configuration in model.properties
    echo "Create configuration in properties file"
    cat <<EOF >>${scriptDir}/model.properties
CLUSTER_SIZE=${wlsClusterSize}
EOF

    echo "Starting generating image model file..."
    modelFilePath="$scriptDir/model.yaml"

    if [[ "${enableSSL,,}" == "true" ]]; then
        chmod ugo+x $scriptDir/genImageModelSSLEnabled.sh
        bash $scriptDir/genImageModelSSLEnabled.sh \
            ${modelFilePath} \
            ${appPackageUrls}
        validate_status "Generate image ssl model file."
    else
        chmod ugo+x $scriptDir/genImageModel.sh
        bash $scriptDir/genImageModel.sh \
            ${modelFilePath} \
            ${appPackageUrls}
        validate_status "Generate image model file."
    fi
}

# Build weblogic image
# Push the image to ACR
function build_wls_image() {
    # Add WDT
    unzip imagetool.zip
    ./imagetool/bin/imagetool.sh cache addInstaller \
        --type wdt \
        --version latest \
        --path ${scriptDir}/model-images/weblogic-deploy.zip

    # Zip wls model and applications
    zip -r ${scriptDir}/model-images/archive.zip wlsdeploy

    # Build image
    echo "Start building WLS image."
    ./imagetool/bin/imagetool.sh update \
        --tag model-in-image:WLS-v1 \
        --fromImage ${wlsImagePath} \
        --wdtModel ${scriptDir}/model.yaml \
        --wdtVariables ${scriptDir}/model.properties \
        --wdtArchive ${scriptDir}/model-images/archive.zip \
        --wdtModelOnly \
        --wdtDomainType WLS \
        --chown oracle:root
    # --additionalBuildCommands ${scriptDir}/nodemanager.dockerfile

    validate_status "Check status of building WLS domain image."

    sudo docker tag model-in-image:WLS-v1 ${acrImagePath}

    # Push image to ACR
    sudo docker logout
    sudo docker login $azureACRServer -u ${azureACRUserName} -p ${azureACRPassword}
    echo "Start pushing image ${acrImagePath} to $azureACRServer."
    sudo docker push -q ${acrImagePath}
    validate_status "Check status of pushing WLS domain image."
    echo "Finish pushing image ${acrImagePath} to $azureACRServer."
}

# Initialize
export script="${BASH_SOURCE[0]}"
export scriptDir="$(cd "$(dirname "${script}")" && pwd)"

export wlsImagePath=$1
export azureACRServer=$2
export azureACRUserName=$3
export azureACRPassword=$4
export imageTag=$5
export appPackageUrls=$6
export ocrSSOUser=$7
export ocrSSOPSW=$8
export wlsClusterSize=$9
export enableSSL=${10}

export acrImagePath="$azureACRServer/aks-wls-images:${imageTag}"
export ocrLoginServer="container-registry.oracle.com"
export wdtDownloadURL="https://github.com/oracle/weblogic-deploy-tooling/releases/download/release-1.9.14/weblogic-deploy.zip"
export witDownloadURL="https://github.com/oracle/weblogic-image-tool/releases/download/release-1.9.12/imagetool.zip"

validate_inputs

initialize

install_utilities

# prepare_certificates

get_wls_image_from_ocr

prepare_wls_models

build_wls_image
