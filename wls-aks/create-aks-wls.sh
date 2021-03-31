export NAME_PREFIX=haiche
# Used to generate resource names.
export TIMESTAMP=`date +%s`
export AKS_CLUSTER_NAME="${NAME_PREFIX}aks${TIMESTAMP}"
export AKS_PERS_RESOURCE_GROUP="${NAME_PREFIX}resourcegroup${TIMESTAMP}"
export AKS_PERS_LOCATION=southeastasia
export LOGIN_SERVER=acrwlsonaks0303.azurecr.io
export USER_NAME=acrwlsonaks0303
export PASSWORD=111111111111111111111111111111
export WLS_OPERATOR_PATH=~/weblogic-kubernetes-operator

# Initialize
script="${BASH_SOURCE[0]}"
scriptDir="$( cd "$( dirname "${script}" )" && pwd )"

# Please login az first

az group create --name $AKS_PERS_RESOURCE_GROUP --location $AKS_PERS_LOCATION
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
cd ${WLS_OPERATOR_PATH}
helm install weblogic-operator kubernetes/charts/weblogic-operator \
  --namespace sample-weblogic-operator-ns \
  --set image=ghcr.io/oracle/weblogic-kubernetes-operator:3.1.1 \
  --set serviceAccount=sample-weblogic-operator-sa \
  --set "enableClusterRoleBinding=true" \
  --set "domainNamespaceSelectionStrategy=LabelSelector" \
  --set "domainNamespaceLabelSelector=weblogic-operator\=enabled" \
  --wait

cd ${scriptDir}

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
   --docker-server=${LOGIN_SERVER} \
   --docker-username=${USER_NAME} \
   --docker-password=${PASSWORD} \
   -n sample-domain1-ns

kubectl apply -f cluster.yaml

# kubectl get pods -n sample-domain1-ns --watch

echo "Create LB for testing"

kubectl apply -f admin-lb.yaml
kubectl apply -f cluster-lb.yaml