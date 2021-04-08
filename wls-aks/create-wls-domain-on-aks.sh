export NAME_PREFIX=wls
# Used to generate resource names.
export TIMESTAMP=`date +%s`
export AKS_CLUSTER_NAME="${NAME_PREFIX}aks${TIMESTAMP}"
export AKS_PERS_RESOURCE_GROUP="${NAME_PREFIX}resourcegroup${TIMESTAMP}"
export ACR_NAME=${NAME_PREFIX}acr${TIMESTAMP}
export AKS_PERS_LOCATION=southeastasia

export wlsOperatorPath=~/weblogic-kubernetes-operator
export oracleSSOAccountName=foo@example.com
export oracleSSOAccountPassword=Secret123!

# Initialize
script="${BASH_SOURCE[0]}"
wlsaksDir="$( cd "$( dirname "${script}" )" && pwd )"

# Please login az first

az group create --name $AKS_PERS_RESOURCE_GROUP --location $AKS_PERS_LOCATION

# Create ACR
az acr create --resource-group $AKS_PERS_RESOURCE_GROUP --name $ACR_NAME --sku Basic --admin-enabled true
acrLoginServer=$(az acr show -n $ACR_NAME --query 'loginServer' -o tsv)
acrUserName=$(az acr credential show -n $ACR_NAME --query 'username' -o tsv)
acrPassword=$(az acr credential show -n $ACR_NAME --query 'passwords[0].value' -o tsv)

# Build WLS domain image and push to ACR
buidDockerImageInput=${wlsaksDir}/wls-domain-image/build-docker-image-inputs.yaml
myBuidDockerImageInput=${wlsaksDir}/wls-domain-image/my-build-docker-image-inputs.yaml
imageVersion=1.0.0
cp ${buidDockerImageInput} ${myBuidDockerImageInput}
sed -i -e "s:azureACRServer.*:azureACRServer\: ${acrLoginServer}:g" ${myBuidDockerImageInput}
sed -i -e "s:azureACRUserName.*:azureACRUserName\: ${acrUserName}:g" ${myBuidDockerImageInput}
sed -i -e "s:azureACRPassword.*:azureACRPassword\: ${acrPassword}:g" ${myBuidDockerImageInput}
sed -i -e "s:dockerEmail.*:dockerEmail\: ${oracleSSOAccountName}:g" ${myBuidDockerImageInput}
sed -i -e "s:dockerUserName.*:dockerUserName\: ${oracleSSOAccountName}:g" ${myBuidDockerImageInput}
sed -i -e "s:dockerPassword.*:dockerPassword\: ${oracleSSOAccountPassword}:g" ${myBuidDockerImageInput}
. ${wlsaksDir}/wls-domain-image/build-docker-image.sh -i ${myBuidDockerImageInput} -b ${imageVersion}

if [ $? -eq 1 ]; then
  echo Failed to build WLS domain image.
  exit 1
fi

imagePath=$acrLoginServer/aks-wls-images:model-in-image-v${imageVersion}
echo image path: ${imagePath}

# create aks
az aks create \
   --resource-group $AKS_PERS_RESOURCE_GROUP \
   --name $AKS_CLUSTER_NAME \
   --node-count 2 \
   --generate-ssh-keys \
   --nodepool-name nodepool1 \
   --node-vm-size Standard_DS2_v2 \
   --location $AKS_PERS_LOCATION \
   --enable-managed-identity
   
az aks get-credentials --resource-group $AKS_PERS_RESOURCE_GROUP --name $AKS_CLUSTER_NAME

kubectl create namespace sample-weblogic-operator-ns
kubectl create serviceaccount -n sample-weblogic-operator-ns sample-weblogic-operator-sa

cd ${wlsOperatorPath}
helm install weblogic-operator kubernetes/charts/weblogic-operator \
  --namespace sample-weblogic-operator-ns \
  --set image=ghcr.io/oracle/weblogic-kubernetes-operator:3.1.1 \
  --set serviceAccount=sample-weblogic-operator-sa \
  --set "enableClusterRoleBinding=true" \
  --set "domainNamespaceSelectionStrategy=LabelSelector" \
  --set "domainNamespaceLabelSelector=weblogic-operator\=enabled" \
  --wait

cd ${wlsaksDir}
kubectl create namespace sample-domain1-ns
kubectl label namespace sample-domain1-ns weblogic-operator=enabled

kubectl -n sample-domain1-ns create secret generic \
  sample-domain1-weblogic-credentials \
   --from-literal=username=weblogic --from-literal=password=welcome1
kubectl -n sample-domain1-ns label  secret \
  sample-domain1-weblogic-credentials \
  weblogic.domainUID=sample-domain1
kubectl -n sample-domain1-ns create secret generic \
  sample-domain1-runtime-encryption-secret \
   --from-literal=password=welcome1
kubectl -n sample-domain1-ns label  secret \
  sample-domain1-runtime-encryption-secret \
  weblogic.domainUID=sample-domain1

kubectl create secret docker-registry regsecret \
   --docker-server=${acrLoginServer} \
   --docker-username=${acrUserName} \
   --docker-password=${acrPassword} \
   -n sample-domain1-ns


clusterInput=${wlsaksDir}/cluster.yaml
myClusterInput=${wlsaksDir}/my-cluster.yaml
cp ${clusterInput} ${myClusterInput}
sed -i -e "s;^image\:.*;image\: \"${imagePath}\";g" ${myClusterInput}
kubectl apply -f ${myClusterInput}

echo "Create LB for testing"

kubectl apply -f admin-lb.yaml
kubectl apply -f cluster-lb.yaml

kubectl get pods -n sample-domain1-ns --watch

