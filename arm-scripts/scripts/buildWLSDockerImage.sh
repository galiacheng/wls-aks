# Initialize
export script="${BASH_SOURCE[0]}"
export scriptDir="$(cd "$(dirname "${script}")" && pwd)"

export wlsImagePath=$1
export azureACRServer=$2
export azureACRUserName=$3
export azureACRPassword=$4
export imageTag=$5

export acrImagePath=$azureACRServer/aks-wls-images:${imageTag}
export wdtDownloadURL="https://github.com/oracle/weblogic-deploy-tooling/releases/download/release-1.9.7/weblogic-deploy.zip";
export witDownloadURL="https://github.com/oracle/weblogic-image-tool/releases/download/release-1.9.5/imagetool.zip"


if [ -d "model-images" ]; then
    rm model-images -f -r
fi

mkdir model-images
cd model-images

# Create Model directory
mkdir wlsdeploy
mkdir wlsdeploy/config
mkdir wlsdeploy/applications

# Step2: download weblogic tools
curl -m 120 -fL ${wdtDownloadURL} -o weblogic-deploy.zip

if [ $? == 1 ]; then
    fail "Download weblogic-deploy.zip failed."
    exit 1
fi

curl -m 120 -fL ${witDownloadURL} -o imagetool.zip

if [ $? == 1 ]; then
    fail "Download imagetool.zip failed."
    exit 1
fi

# Step3: add WDT
unzip imagetool.zip
./imagetool/bin/imagetool.sh cache addInstaller \
    --type wdt \
    --version latest \
    --path ${scriptDir}/model-images/weblogic-deploy.zip

# Zip wls model and applications
zip -r ${scriptDir}/model-images/archive.zip wlsdeploy

# Step5: build image
./imagetool/bin/imagetool.sh update \
    --tag model-in-image:WLS-v1 \
    --fromImage ${wlsImagePath} \
    --wdtModel ${scriptDir}/model.yaml \
    --wdtVariables ${scriptDir}/model.properties \
    --wdtArchive ${scriptDir}/model-images/archive.zip \
    --wdtModelOnly \
    --wdtDomainType WLS \
    --chown oracle:oracle

if [ $? == 1 ]; then
    fail "Build image failed."
    exit 1
fi

docker tag model-in-image:WLS-v1 ${acrImagePath}

# Step6: push image to ACR
docker logout
docker login $azureACRServer -u ${azureACRUserName} -p ${azureACRPassword}

docker push ${acrImagePath}

if [ $? == 1 ]; then
    fail "Push image ${acrImagePath} failed."
    exit 1
fi
