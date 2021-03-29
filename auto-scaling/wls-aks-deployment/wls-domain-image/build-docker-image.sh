# Initialize
script="${BASH_SOURCE[0]}"
scriptDir="$( cd "$( dirname "${script}" )" && pwd )"

function usage {
  echo usage: ${script} -i file [-b] [-h]
  echo "  -i Parameter inputs file, must be specified."
  echo "  -b Build number."
  echo "  -h Help"
  exit $1
}

#
# Function to exit and print an error message
# $1 - text of message
function fail {
  echo [ERROR] $*
  exit 1
}

#
# Function to parse a yaml file and generate the bash exports
# $1 - Input filename
# $2 - Output filename
function parseYaml {
  local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
  sed -ne "s|^\($s\):|\1|" \
     -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
     -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
  awk -F$fs '{
    if (length($3) > 0) {
      # javaOptions may contain tokens that are not allowed in export command
      # we need to handle it differently. 
      if ($2=="javaOptions") {
        printf("%s=%s\n", $2, $3);
      } else {
        printf("export %s=\"%s\"\n", $2, $3);
      }
    }
  }' > $2
}

function printSummary {
  echo ""
  echo ""
  echo "Completed!"
  echo "Please find the image in: $azureACRServer/aks-wls-images:model-in-image-v${imageVersion}"
}

function cleanup {
  cd ${scriptDir}
  rm -f -r imagetool
  rm -f archive.zip
  rm -f weblogic-deploy.zip
  rm -f imagetool.zip
}

# Main script
#
# Parse the command line options
#
executeIt=false
while getopts "hi:b:" opt; do
  case $opt in
    i) valuesInputFile="${OPTARG}"
    ;;
    b) buildNumber="${OPTARG}"
    ;;
    h) usage 0
    ;;
    *) usage 1
    ;;
  esac
done

# Init
# Import inputs
# Parse domain configuration yaml for usage in load balancer
exportValuesFile=$(mktemp /tmp/export-values-XXXXXXXXX.sh)
tmpFile=$(mktemp /tmp/javaoptions_tmp-XXXXXXXXX.dat) 
parseYaml ${valuesInputFile} ${exportValuesFile}
if [ ! -f ${exportValuesFile} ]; then
  echo Unable to locate the parsed inputs of ${valuesInputFile}.
  fail 'The file ${exportValuesFile} could not be found.'
fi

# Define the environment variables that will be used to fill in template values
echo Domain parameters being used
cat ${exportValuesFile}
echo
# javaOptions may contain tokens that are not allowed in export command
# we need to handle it differently. 
# we set the javaOptions variable that can be used later
tmpStr=`grep "javaOptions" ${exportValuesFile}`
javaOptions=${tmpStr//"javaOptions="/}

# We exclude javaOptions from the exportValuesFile
grep -v "javaOptions" ${exportValuesFile} > ${tmpFile}
source ${tmpFile}
rm ${exportValuesFile} ${tmpFile}

# use build number
if [ -n "${buildNumber}" ];then
  imageVersion=${buildNumber}
fi

# Step1: pull weblogic images from Oracle Container Registry.
# Need an Oracle SSO account. Create one in https://profile.oracle.com/myprofile/account/create-account.jspx# 
echo "Login docker"
docker logout
docker login -u ${dockerEmail} -p ${dockerPassword} container-registry.oracle.com
docker pull container-registry.oracle.com/middleware/weblogic:12.2.1.4

if [  $? == 1 ];then
  fail "Pull weblogic image from OCR failed."
  exit 1
fi


# Step2: download weblogic tools
cd ${scriptDir}

curl -m 120 -fL https://github.com/oracle/weblogic-deploy-tooling/releases/download/release-1.9.7/weblogic-deploy.zip \
  -o ${scriptDir}/weblogic-deploy.zip

if [  $? == 1 ];then
  fail "Download weblogic-deploy.zip failed."
  exit 1
fi

curl -m 120 -fL https://github.com/oracle/weblogic-image-tool/releases/download/release-1.9.5/imagetool.zip \
  -o ${scriptDir}/imagetool.zip

if [  $? == 1 ];then
  fail "Download imagetool.zip failed."
  exit 1
fi


# Step3: prepare
rm imagetool -f -r
unzip imagetool.zip
./imagetool/bin/imagetool.sh cache deleteEntry --key=wdt_latest
./imagetool/bin/imagetool.sh cache addInstaller \
  --type wdt \
  --version latest \
  --path ${scriptDir}/weblogic-deploy.zip

rm -f ${scriptDir}/archive.zip

cd ${scriptDir}
zip -r ${scriptDir}/archive.zip wlsdeploy

# Step5: build image
docker rmi model-in-image:WLS-v1 --force
./imagetool/bin/imagetool.sh update \
  --tag model-in-image:WLS-v1 \
  --fromImage container-registry.oracle.com/middleware/weblogic:12.2.1.4 \
  --wdtModel      ./model.yaml \
  --wdtVariables  ./model.properties \
  --wdtArchive    ./archive.zip \
  --wdtModelOnly \
  --wdtDomainType WLS \
  --chown oracle:root

if [  $? == 1 ];then
  fail "Build image failed."
  exit 1
fi

docker images | grep WLS-v1

docker tag model-in-image:WLS-v1 $azureACRServer/aks-wls-images:model-in-image-v${imageVersion}

# Step6: push image to ACR
docker logout
docker login $azureACRServer -u ${azureACRUserName} -p ${azureACRPassword}

docker push $azureACRServer/aks-wls-images:model-in-image-v${imageVersion}

if [  $? == 1 ];then
  fail "Push image $azureACRServer/aks-wls-images:model-in-image-v${imageVersion} failed."
  exit 1
fi

cleanup

printSummary


