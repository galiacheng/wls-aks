The [script](curl-app.sh) will access `http:/${clusterIP}:8001/testwebapp/` 22 times using `curl`. It will generate 22 sessions, for rule `webapp:webapp_config_open_sessions_current_count:avg > 10` the WLS cluster should have at least 3 managed server pods. The session will be kept for 80s, after they are timeout, he WLS cluster should terminate 2 managed server pods.

Command to run the script:

```bash
# get cluster ip
$ kubectl get svc -n sample-domain1-ns | grep "sample-domain1-cluster-lb"
$ ./curl-app.sh <cluster-public-ip>
```