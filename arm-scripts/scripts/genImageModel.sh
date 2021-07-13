# Initialize
export script="${BASH_SOURCE[0]}"
export scriptDir="$(cd "$(dirname "${script}")" && pwd)"

export filePath=$1
export appPackageUrls=$2
export enableCustomSSL=$3

cat <<EOF >${filePath}
# Copyright (c) 2020, 2021, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# Based on ./kubernetes/samples/scripts/create-weblogic-domain/model-in-image/model-images/model-in-image__WLS-v1/model.10.yaml
# in https://github.com/oracle/weblogic-kubernetes-operator.

domainInfo:
  AdminUserName: "@@SECRET:__weblogic-credentials__:username@@"
  AdminPassword: "@@SECRET:__weblogic-credentials__:password@@"
  ServerStartMode: "prod"
  domainLibraries: [ 'wlsdeploy/domainLibraries/postgresql-42.2.8.jar', 'wlsdeploy/domainLibraries/mssql-jdbc-7.4.1.jre8.jar']

topology:
  Name: "@@ENV:CUSTOM_DOMAIN_NAME@@"
  ProductionModeEnabled: true
  AdminServerName: "admin-server"
  Cluster:
    "cluster-1":
      DynamicServers:
        ServerTemplate: "cluster-1-template"
        ServerNamePrefix: "@@ENV:MANAGED_SERVER_PREFIX@@"
        DynamicClusterSize: "@@PROP:CLUSTER_SIZE@@"
        MaxDynamicClusterSize: "@@PROP:CLUSTER_SIZE@@"
        MinDynamicClusterSize: "0"
        CalculatedListenPorts: false
  Server:
    "admin-server":
      ListenPort: 7001
EOF

if [[ "${enableCustomSSL,,}" == "true" ]];then
  cat <<EOF >>${filePath}
      SSL:
        HostnameVerificationIgnored: true
        ListenPort: 7002
        Enabled: true
        HostnameVerifier: 'None'
        ServerPrivateKeyAlias: "@@ENV:SSL_IDENTITY_PRIVATE_KEY_ALIAS@@"
        ServerPrivateKeyPassPhraseEncrypted: "@@ENV:SSL_IDENTITY_PRIVATE_KEY_PSW@@"
      KeyStores: 'CustomIdentityAndCustomTrust'
      CustomIdentityKeyStoreFileName: "@@ENV:SSL_IDENTITY_PRIVATE_KEYSTORE_PATH@@"
      CustomIdentityKeyStoreType: "@@ENV:SSL_IDENTITY_PRIVATE_KEYSTORE_TYPE@@"
      CustomIdentityKeyStorePassPhraseEncrypted: "@@ENV:SSL_IDENTITY_PRIVATE_KEYSTORE_PSW@@"
      CustomTrustKeyStoreFileName: "@@ENV:SSL_TRUST_KEYSTORE_PATH@@"
      CustomTrustKeyStoreType: "@@ENV:SSL_TRUST_KEYSTORE_TYPE@@"
      CustomTrustKeyStorePassPhraseEncrypted: "@@ENV:SSL_TRUST_KEYSTORE_PSW@@"
EOF
else
  cat <<EOF >>${filePath}
      SSL:
        ListenPort: 7002
        Enabled: true
EOF
fi

cat <<EOF >>${filePath}
  ServerTemplate:
    "cluster-1-template":
      Cluster: "cluster-1"
      ListenPort: 8001
EOF

if [[ "${enableCustomSSL,,}" == "true" ]];then
  cat <<EOF >>${filePath}
      SSL:
        HostnameVerificationIgnored: true
        ListenPort: 8002
        Enabled: true
        HostnameVerifier: 'None'
        ServerPrivateKeyAlias: "@@ENV:SSL_IDENTITY_PRIVATE_KEY_ALIAS@@"
        ServerPrivateKeyPassPhraseEncrypted: "@@ENV:SSL_IDENTITY_PRIVATE_KEY_PSW@@"
      KeyStores: 'CustomIdentityAndCustomTrust'
      CustomIdentityKeyStoreFileName: "@@ENV:SSL_IDENTITY_PRIVATE_KEYSTORE_PATH@@"
      CustomIdentityKeyStoreType: "@@ENV:SSL_IDENTITY_PRIVATE_KEYSTORE_TYPE@@"
      CustomIdentityKeyStorePassPhraseEncrypted: "@@ENV:SSL_IDENTITY_PRIVATE_KEYSTORE_PSW@@"
      CustomTrustKeyStoreFileName: "@@ENV:SSL_TRUST_KEYSTORE_PATH@@"
      CustomTrustKeyStoreType: "@@ENV:SSL_TRUST_KEYSTORE_TYPE@@"
      CustomTrustKeyStorePassPhraseEncrypted: "@@ENV:SSL_TRUST_KEYSTORE_PSW@@"
EOF
else
  cat <<EOF >>${filePath}
      SSL:
        ListenPort: 8002
        Enabled: true
EOF
fi

cat <<EOF >>${filePath}
  SecurityConfiguration:
    NodeManagerUsername: "@@SECRET:__weblogic-credentials__:username@@"
    NodeManagerPasswordEncrypted: "@@SECRET:__weblogic-credentials__:password@@"
    
resources:
  SelfTuning:
    MinThreadsConstraint:
      SampleMinThreads:
        Target: "cluster-1"
        Count: 1
    MaxThreadsConstraint:
      SampleMaxThreads:
        Target: "cluster-1"
        Count: 10
    WorkManager:
      SampleWM:
        Target: "cluster-1"
        MinThreadsConstraint: "SampleMinThreads"
        MaxThreadsConstraint: "SampleMaxThreads"

EOF

if [ "${appPackageUrls}" == "[]" ]; then
        return
    fi

    cat <<EOF >>${filePath}
appDeployments:
  Application:
EOF
    appPackageUrls=$(echo "${appPackageUrls:1:${#appPackageUrls}-2}")
    appUrlArray=$(echo $appPackageUrls | tr "," "\n")

    index=1
    for item in $appUrlArray; do
        # e.g. https://wlsaksapp.blob.core.windows.net/japps/testwebapp.war?sp=r&se=2021-04-29T15:12:38Z&sv=2020-02-10&sr=b&sig=7grL4qP%2BcJ%2BLfDJgHXiDeQ2ZvlWosRLRQ1ciLk0Kl7M%3D
        fileNamewithQueryString="${item##*/}"
        fileName="${fileNamewithQueryString%\?*}"
        fileExtension="${fileName##*.}"
        curl -m 120 -fL "$item" -o ${scriptDir}/model-images/wlsdeploy/applications/${fileName}
        cat <<EOF >>${filePath}
    app${index}:
      SourcePath: 'wlsdeploy/applications/${fileName}'
      ModuleType: ear
      Target: 'cluster-1'
EOF
        index=$((index + 1))
    done