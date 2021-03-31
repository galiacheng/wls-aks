### Auto-scaling for running WLS on AKS using Prometheus
This is a sample of auto-scaling for running WLS on AKS using Prometheus. 
Following the guide you can customize your scaling flows.

#### Prerequisites

- Docker Hub account, if you don't have one, go to [Docker Hub Sign-up](https://hub.docker.com/) to create one.
- [Docker for Desktop](https://www.docker.com/products/docker-desktop). This document was tested with Docker version 20.10.2, build 2291f61
- [kubectl](https://kubernetes-io-vnext-staging.netlify.com/docs/tasks/tools/install-kubectl/); use kubectl version to test if kubectl works. This document was tested with version v1.16.3.
- [Helm](https://helm.sh/docs/intro/install/), version 3.1 and later; use helm version to check the helm version. This document was tested with version v3.2.4.
- JDK 8 or 11.
- Assuming you are creating the WLS domain with guide in this sample, otherwise, you have to change the domain UID and cluster name for all the configurations in manifests folder.

##### Weblogic Monitoring Exporter

- [Repository and documentation](https://github.com/oracle/weblogic-monitoring-exporter)

##### Promethues

- [kube-prometheus](https://github.com/prometheus-operator/kube-prometheus)
- [prometheus-operator](https://github.com/prometheus-operator/prometheus-operator)
- [prometheus](https://github.com/prometheus/prometheus)
- [Prometheus Documents](https://prometheus.io/)

##### Running WLS on AKS custer

- Follow [this document](wls-aks/README.md) to create one.

#### Build webhook image and push to ACR

Firstly, you need to login docker.io with 

`docker login docker.io -u <your-docker-user-id> -p <your-docker-password>`

Build the webhook image with the following commands:

```bash
# cd wls-aks/auto-scaling
$ docker image build -t webhook:1.0 ./wehhook
[+] Building 4.3s (12/12) FINISHED                                                                                                                     
 => [internal] load build definition from Dockerfile                                                                                              0.1s
 => => transferring dockerfile: 38B                                                                                                               0.0s
 => [internal] load .dockerignore                                                                                                                 0.0s
 => => transferring context: 2B                                                                                                                   0.0s
 => [internal] load metadata for docker.io/store/oracle/serverjre:8                                                                               4.0s
 => [auth] store/oracle/serverjre:pull token for registry-1.docker.io                                                                             0.0s
 => [1/6] FROM docker.io/store/oracle/serverjre:8@sha256:309c408ef0482e119ee838923a2caf016d12732c47a3bc291e81d020bbf5846b                         0.0s
 => [internal] load build context                                                                                                                 0.1s
 => => transferring context: 288B                                                                                                                 0.1s
 => CACHED [2/6] COPY apps/webhook /bin/webhook                                                                                                   0.0s
 => CACHED [3/6] COPY webhooks/hooks.json /etc/webhook/                                                                                           0.0s
 => CACHED [4/6] COPY scripts/scaleUpAction.sh /var/scripts/                                                                                      0.0s
 => CACHED [5/6] COPY scripts/scaleDownAction.sh /var/scripts/                                                                                    0.0s
 => CACHED [6/6] COPY scripts/scalingAction.sh /var/scripts/                                                                                      0.0s
 => exporting to image                                                                                                                            0.0s
 => => exporting layers                                                                                                                           0.0s
 => => writing image sha256:0846a7d6f9a5c5e82141dabef1843c946e7564ec558797e5593523082321caca                                                      0.0s
 => => naming to docker.io/library/webhook:1.0  
```

Tag the image and push to ACR.

```bash
$ docker tag webhook:1.0 <acr-login-server>/webhook:1.0
$ docker login <acr-login-server> -u <acr-user> -p <acr-password>
$ docker push <acr-login-server>/webhook:1.0
```

#### Deploy Promethues

```bash
# cd wls-aks
$ kubectl create -f manifests/setup
$ until kubectl get servicemonitors --all-namespaces ; do date; sleep 1; echo ""; done
$ kubectl create -f manifests/
```

#### Deploy WLS rules and webhook

```bash
$ export LOGIN_SERVER=acrwlsonaks0303.azurecr.io
$ export USER_NAME=acrwlsonaks0303
$ export PASSWORD=1111
$ kubectl create secret docker-registry regsecret \
   --docker-server=${LOGIN_SERVER} \
   --docker-username=${USER_NAME} \
   --docker-password=${PASSWORD} \
   -n monitoring

$ kubectl create -f manifests/wls-aks
```


