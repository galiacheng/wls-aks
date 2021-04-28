#Function to output message to StdErr
function echo_stderr() {
    echo "$@" >&2
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
        exit 1
    fi

    if [ -z "$azureACRServer" ]; then
        echo_stderr "azureACRServer is required. "
        exit 1
    fi

    if [ -z "$azureACRUserName" ]; then
        echo_stderr "azureACRUserName is required. "
        exit 1
    fi

    if [ -z "$azureACRPassword" ]; then
        echo_stderr "azureACRPassword is required. "
        exit 1
    fi

    if [ -z "$imageTag" ]; then
        echo_stderr "imageTag is required. "
        exit 1
    fi

    if [ -z "$appPackageUrl" ]; then
        echo_stderr "appPackageUrl is required. "
        exit 1
    fi

    if [ -z "$ocrSSOUser" ]; then
        echo_stderr "ocrSSOUser is required. "
        exit 1
    fi

    if [ -z "$ocrSSOPSW" ]; then
        echo_stderr "ocrSSOPSW is required. "
        exit 1
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
}

# Install docker, kubectl, helm and java
function install_utilities() {
    # Install docker
    sudo apt-get update
    sudo apt-get -y -q install apt-transport-https
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get -y -q install docker-ce docker-ce-cli containerd.io

    echo "docker version"
    sudo docker --version
    validate_status "Check status of docker."

    # Install Zulu JDK 8
    sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 0xB1998361219BD9C9
    sudo apt-add-repository "deb http://repos.azul.com/azure-only/zulu/apt stable main"
    sudo apt-get -q update
    sudo apt-get -y -q -y install zulu-8-azure-jdk
    echo "java version"
    java -version
    validate_status "Check status of Zulu JDK 8."

    export JAVA_HOME=/usr/lib/jvm/zulu-8-azure-amd64
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

function get_wls_image_from_ocr() {
    sudo docker logout
    sudo docker login ${ocrLoginServer} -u ${ocrSSOUser} -p ${ocrSSOPSW}
    echo "Start to pull image ${wlsImagePath}"
    sudo docker pull -q ${wlsImagePath}
    validate_status "Finish pulling image from OCR."
}

function prepare_wls_models() {
    # TODO change the application name
    # curl -m 120 -fL "$appPackageUrl" -o wlsdeploy/applications/test.war
    echo download apps
}

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
export appPackageUrl=$6
export ocrSSOUser=$7
export ocrSSOPSW=$8

export acrImagePath="$azureACRServer/aks-wls-images:${imageTag}"
export ocrLoginServer="container-registry.oracle.com"
export wdtDownloadURL="https://github.com/oracle/weblogic-deploy-tooling/releases/download/release-1.9.7/weblogic-deploy.zip"
export witDownloadURL="https://github.com/oracle/weblogic-image-tool/releases/download/release-1.9.11/imagetool.zip"

validate_inputs

initialize

install_utilities

get_wls_image_from_ocr

prepare_wls_models

build_wls_image
