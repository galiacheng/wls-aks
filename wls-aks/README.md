Use script `create-wls-domain-on-aks.sh` to create sample domain.

1. Clone the WebLogic Operator.

```bash
cd ~
git clone https://github.com/oracle/weblogic-kubernetes-operator.git
```

Before running the script, please replace the following value with yours.

| Name in Shell file | Example value | Notes |
|-------------------|---------------|-------|
| `wlsOperatorPath` | `~/weblogic-kubernetes-operator` | Must be the same with the path you clone the repo. |
| `oracleSSOAccountName` | `foo@example.com` | Oracle Single Sign-On (SSO) account email, used to pull the WebLogic Server image. |
| `oracleSSOAccountPassword` | `Secret123!` | Oracle SSO account password, used to pull the WebLogic Server image. |


2. Run the script

```bash
cd wls-aks
./create-wls-domain-on-aks.sh
```

Press `ctrl` + `c` to stop the script once the weblogic servers are up.