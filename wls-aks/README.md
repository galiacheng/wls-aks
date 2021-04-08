Prerequisites

- [Docker for Desktop](https://www.docker.com/products/docker-desktop). This document was tested with Docker version 20.10.2, build 2291f61
- [kubectl](https://kubernetes-io-vnext-staging.netlify.com/docs/tasks/tools/install-kubectl/); use kubectl version to test if kubectl works. This document was tested with version v1.16.3.
- [Helm](https://helm.sh/docs/intro/install/), version 3.1 and later; use helm version to check the helm version. This document was tested with version v3.2.4.
- Git.
- JDK 8 or 11.

Use script `create-wls-domain-on-aks.sh` to create sample domain.

1. Clone the WebLogic Operator.

```bash
$ cd ~
$ git clone https://github.com/oracle/weblogic-kubernetes-operator.git
```

Before running the script, please replace the following value with yours.

| Name in Shell file | Example value | Notes |
|-------------------|---------------|-------|
| `wlsOperatorPath` | `~/weblogic-kubernetes-operator` | Must be the same with the path you clone the repo. |
| `oracleSSOAccountName` | `foo@example.com` | Oracle Single Sign-On (SSO) account email, used to pull the WebLogic Server image. |
| `oracleSSOAccountPassword` | `Secret123!` | Oracle SSO account password, used to pull the WebLogic Server image. |


2. Run the script

```bash
# Set Java Home
$ export JAVA_HOME=/usr/lib/jvm/jdk1.8.0_261
$ cd wls-aks
$ ./create-wls-domain-on-aks.sh
```

Stop the script pressing `ctrl` + `c` when you find output like:

```text
NAME                                READY   STATUS              RESTARTS   AGE
sample-domain1-introspector-xftm9   0/1     ContainerCreating   0          5s
sample-domain1-introspector-xftm9   1/1     Running             0          31s
sample-domain1-introspector-xftm9   0/1     Completed           0          99s
sample-domain1-introspector-xftm9   0/1     Terminating         0          99s
sample-domain1-introspector-xftm9   0/1     Terminating         0          99s
sample-domain1-admin-server         0/1     Pending             0          0s
sample-domain1-admin-server         0/1     Pending             0          0s
sample-domain1-admin-server         0/1     ContainerCreating   0          0s
sample-domain1-admin-server         0/1     Running             0          2s
sample-domain1-admin-server         1/1     Running             0          35s
sample-domain1-managed-server1      0/1     Pending             0          0s
sample-domain1-managed-server1      0/1     Pending             0          0s
sample-domain1-managed-server1      0/1     ContainerCreating   0          0s
sample-domain1-managed-server1      0/1     Running             0          3s
sample-domain1-managed-server1      1/1     Running             0          48s
```