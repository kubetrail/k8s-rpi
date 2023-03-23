## Kubernetes on Raspberry Pi nodes
Install [k0s](https://github.com/k0sproject) distribution of Kubernetes on Raspberry Pi 
nodes and deploy [NFS](https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner) 
storage layer for dynamic provisioning of volumes.

## disclaimer
> The use of this setup does not guarantee security or usability for any
> particular purpose whether for production use case or personal home automation
> use cases. Please review the code and use at your own risk.

## hardware
* Raspberry PI 4 with 8GB memory (3 nodes)
* An external USB3 drive for `etcd` data store and persistent volume storage

Additionally, make sure the network has reserved (or static) IP addresses for these nodes

### node prep
Download and install the latest [64-bit Lite OS](https://downloads.raspberrypi.org/raspios_arm64/images),
or optionally install 64-bit lite OS 
using [Raspberry Pi imager](https://www.raspberrypi.com/news/raspberry-pi-imager-imaging-utility/)

Once the nodes are up run `sudo rapi-config` command to:
* Setup hostnames `rpi4-0`, `rpi4-1`, `rpi4-2` and so on
* Enable SSH (and I2C interfaces if needed) on all nodes
* Change default password for user `pi` (highly recommended)

Reboot nodes.

Install `cgroups` on all nodes
```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y cgroups*
```

Add following text to `/boot/cmdline.txt` on all nodes
```
cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1
```

`rpi4-0` node will become the `control-plane`, while the other two nodes will 
assume `worker` roles

Reboot nodes.

## control-plane node setup on rpi4-0
Install `k0s` and `kubectl`:
```bash
curl -sSLf https://get.k0s.sh | sudo sh
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/arm64/kubectl"
chmod 755 kubectl
sudo cp kubectl /usr/local/bin/
rm -rf kubectl
mkdir .kube
```

Add following to your `.bashrc`:
```bash
source <(kubectl completion bash)
```

This node will also work as `storage` node, so attach external drive and format
it with `ext4` file system. Auto-mount external storage by configuring `/etc/fstab` file:

There may be prep steps for the attached block device such as formatting and wiping off
existing filesystems. Here are some commands to try to clean up and format the device
before use:
```bash
sudo mkfs.ext4 /dev/sda
sudo wipefs -a /dev/sda
sudo sgdisk --zap-all /dev/sda
```

The `/etc/fstab` may look something as follows:
```bash
cat /etc/fstab 
proc            /proc           proc    defaults          0       0
PARTUUID=********-01  /boot           vfat    defaults,flush    0       2
PARTUUID=********-02  /               ext4    defaults,noatime  0       1
# a swapfile is not a swap partition, no line here
#   use  dphys-swapfile swap[on|off]  for that
UUID=your-device-UUID /mnt/k8s ext4 nosuid,nodev,nofail 0 2
```
Confirm automount is working by rebooting the node.

Create a folder to store persistent volume data:
```bash
sudo mkdir -p /mnt/k8s/local-path-provisioner
```

### setup k0s
`ssh` to `rpi4-0` and generate `default-config` for `k0s`:
```bash
sudo k0s config create > default-config.yaml
```

Add `extraArgs` section to the `default-config` file. The `yaml`
snippet shown below only highlights the changes and there is a lot
more info in the `default-config`
```yaml
apiVersion: k0s.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: k0s
spec:
  api:
    extraArgs:
      oidc-issuer-url: https://accounts.google.com 
      oidc-username-claim: email
      oidc-client-id: 32555940559.apps.googleusercontent.com
```

Copy the file from above to a folder:
```bash
sudo mkdir -p /etc/k0s/
sudo cp default-config.yaml /etc/k0s/
rm -rf default-config.yaml
```

Now reboot the node and then install `k0s` controller
```bash
sudo k0s install controller \
    --enable-worker \
    --no-taints \
    --config=/etc/k0s/default-config.yaml \
    --data-dir=/mnt/k8s/k0s
```

Make sure the file `/etc/systemd/system/k0scontroller.service` contains ETCD env.
variable `Environment=ETCD_UNSUPPORTED_ARCH=arm64` similar to the one shown below.
```
[Unit]
Description=k0s - Zero Friction Kubernetes
Documentation=https://docs.k0sproject.io
ConditionFileIsExecutable=/usr/local/bin/k0s

After=network-online.target 
Wants=network-online.target 

[Service]
StartLimitInterval=5
StartLimitBurst=10
Environment=ETCD_UNSUPPORTED_ARCH=arm64
ExecStart=/usr/local/bin/k0s controller --config=/etc/k0s/default-config.yaml --data-dir=/mnt/k8s/k0s --single=true
```

Start the service and check status
```bash
sudo systemctl daemon-reload
sudo k0s start
sudo k0s status
```

wait a bit and then ensure that the status is ok
```text
Version: v1.24.4+k0s.0
Process ID: 883
Role: controller
Workloads: true
SingleNode: false
```

### generate kubeconfig and connect
```bash
mkdir -p ${HOME}/.kube
sudo k0s kubeconfig create \
    --data-dir=/mnt/k8s/k0s \
    --groups "system:masters" k0s > ${HOME}/.kube/config
chmod 644 ${HOME}/.kube/config
```

```bash
kubectl get nodes -o wide
NAME     STATUS   ROLES                  AGE   VERSION       INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION   CONTAINER-RUNTIME
rpi4-0   Ready    control-plane          9h    v1.23.3+k0s   ***.***.*.**   <none>        Debian GNU/Linux 11 (bullseye)   5.10.103-v8+     containerd://1.5.9
```

Enable a user who would be accessing the cluster as an admin, 
by giving permissions via cluster role binding. Also label nodes that
will act as storage node. This is the node where external drive is
attached and mounted.
```bash
kubectl label nodes rpi4-0 kubernetes.io/storage=storage
kubectl create clusterrolebinding user-crb --clusterrole=cluster-admin --user=user@example.com
```

### access cluster externally
In order to access cluster externally copy the `kubeconfig` file and make changes to the `user` section
to allow `gcloud` CLI work as an auth provider. An example `kubeconfig` is shown below with cert authority
data redacted. Make sure cert authority data is populated per your control plane node `kubeconfig` file.

This way a user sends their OIDC compatible ID token to the API server and such token is being
generated using `gcloud`. However, `gcloud` output needs to be reformatted to comply with the
requirements of the `ExecCredential` format. This can be easily done by wrapping `gcloud`
in a shell script `rpi-gcloud-auth-plugin.sh`.

```yaml
kind: Config
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: redacted=
    server: https://control-plane-node-ip:6443
  name: k0s
contexts:
- context:
    cluster: k0s
    user: k0s
  name: k0s
current-context: k0s
preferences: {}
users:
- name: k0s
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: rpi-gcloud-auth-plugin.sh
      installHint: Install gke-gcloud-auth-plugin for use with kubectl by following
        https://cloud.google.com/blog/products/containers-kubernetes/kubectl-auth-changes-in-gke
      provideClusterInfo: true
```

At this point the cluster can be accessed externally:
```bash
kubectl get nodes -o wide
```
```text
NAME     STATUS   ROLES                  AGE   VERSION       INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION   CONTAINER-RUNTIME
rpi4-0   Ready    control-plane          9h    v1.23.3+k0s   ***.***.*.**   <none>        Debian GNU/Linux 11 (bullseye)   5.10.103-v8+     containerd://1.5.9
```

Finally, create a join token to allow worker nodes to join the cluster
```bash
sudo k0s token create \
    --data-dir=/mnt/k8s/k0s \
    --role worker > join-token
```

Copy the `join-token` on all worker nodes

## worker node setup
Do these steps on all worker nodes

### join workers
Assuming `join-token` exists on all worker nodes, do
```bash
sudo mkdir -p /var/lib/k0s/
sudo cp join-token /var/lib/k0s/
sudo rm -rf join-token
sudo k0s install worker --token-file /var/lib/k0s/join-token
sudo systemctl daemon-reload
sudo systemctl enable --now k0sworker
```

Assign labels to `worker` nodes as needed
```bash
kubectl label nodes rpi4-1 node-role.kubernetes.io/worker=worker
kubectl label nodes rpi4-2 node-role.kubernetes.io/worker=worker
kubectl label nodes rpi4-1 kubernetes.io/bme280=sensor
kubectl label nodes rpi4-1 kubernetes.io/sgp30=sensor
```

At this point the 3-node cluster should be ready.
```bash
kubectl get nodes -o wide
```
```text
NAME     STATUS   ROLES                  AGE   VERSION       INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION   CONTAINER-RUNTIME
rpi4-0   Ready    control-plane          9h    v1.23.3+k0s   ***.***.*.**   <none>        Debian GNU/Linux 11 (bullseye)   5.10.103-v8+     containerd://1.5.9
rpi4-1   Ready    worker                 58m   v1.23.3+k0s   ***.***.*.**   <none>        Debian GNU/Linux 11 (bullseye)   5.10.103-v8+     containerd://1.5.9
rpi4-2   Ready    worker                 58m   v1.23.3+k0s   ***.***.*.**   <none>        Debian GNU/Linux 11 (bullseye)   5.10.103-v8+     containerd://1.5.9
```

At this point following pods should be up and running on the cluster
```bash
kubectl get pods --all-namespaces
```
```text
NAMESPACE     NAME                              READY   STATUS    RESTARTS       AGE
kube-system   coredns-6d9f49dcbb-8cd95          1/1     Running   0              11h
kube-system   coredns-6d9f49dcbb-fv78d          1/1     Running   0              153m
kube-system   kube-proxy-97cp8                  1/1     Running   0              153m
kube-system   kube-proxy-s7rrq                  1/1     Running   0              153m
kube-system   kube-proxy-trrsr                  1/1     Running   0              11h
kube-system   kube-router-6xzqn                 1/1     Running   0              153m
kube-system   kube-router-ph2gf                 1/1     Running   0              11h
kube-system   kube-router-xl28r                 1/1     Running   0              153m
kube-system   metrics-server-74c967d8d4-wlfj9   1/1     Running   0              11h
```

## deploy components on cluster
Now that the cluster is up and running, we can deploy components that will allow us
to issue certificates and dynamically provision storage volumes via NFS based storage
layer.

This step assumes you have [Go compiler toolchain](https://go.dev/dl/)
installed on your system.

This section installs three components on the clusters:
* cert manager for issuing certificates
* local path storage for enabling storage base layer
* nfs for enabling storage on top of local path storage

The `nfs` storage requires a docker container that you can
optionally, build and push to your repository. If you skip
this step, a default upstream image will be used in the manifests.
```bash
export IMG="your-registry/nfs:v3.0.0"
make docker-build
make docker-push
```

Once image is available on your repo, you can build manifests.
Alternatively, if you did not build and push your own image, the default
image will be used.
```bash
make deploy-manifests
```

This will now produce deployable manifests in `config/samples/manifests.yaml`,
which you can manually deploy using `kubectl`
> Please remove the image-pull-secrets section when using default images
> or when your image is publicly available.

Launch an example `pod` and `pvc` that uses `nfs` based dynamic provisioning:
```bash
make deploy-examples
```

At this point following component pods should be up and running.
```
kubectl get pods,pv,pvc --all-namespaces -o wide

NAMESPACE      NAME                                           READY   STATUS    RESTARTS      AGE    IP             NODE     NOMINATED NODE   READINESS GATES
cert-manager   pod/cert-manager-5b6d4f8d44-nkjcz              1/1     Running   0             2m8s   10.244.0.22    rpi4-0   <none>           <none>
cert-manager   pod/cert-manager-cainjector-747cfdfd87-rlt2w   1/1     Running   0             2m8s   10.244.1.14    rpi4-2   <none>           <none>
cert-manager   pod/cert-manager-webhook-67cb765ff6-bts4w      1/1     Running   0             2m8s   10.244.0.23    rpi4-0   <none>           <none>
nfs-example    pod/pod-using-nfs                              1/1     Running   0             75s    10.244.0.27    rpi4-0   <none>           <none>
nfs-system     pod/nfs-provisioner-0                          1/1     Running   0             2m8s   10.244.0.26    rpi4-0   <none>           <none>
stor-system    pod/local-path-provisioner-65bbf76f85-vqtj8    1/1     Running   0             2m8s   10.244.0.24    rpi4-0   <none>           <none>

NAMESPACE   NAME                                                        CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM			 STORA
GECLASS   REASON   AGE    VOLUMEMODE
            persistentvolume/pvc-b42b3e28-ace1-45ad-9e1c-c99730a91377   1Gi        RWO            Delete           Bound    nfs-example/nfs		 nfs
                   75s    Filesystem
            persistentvolume/pvc-e7c1f218-f2f7-4ca5-a031-fb82bd1c1818   64Gi	   RWO            Delete           Bound    nfs-system/nfs-provisioner   local
-path              2m3s   Filesystem

NAMESPACE     NAME                                    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE    VOLU
MEMODE
nfs-example   persistentvolumeclaim/nfs               Bound    pvc-b42b3e28-ace1-45ad-9e1c-c99730a91377   1Gi        RWO            nfs            75s    File
system
nfs-system    persistentvolumeclaim/nfs-provisioner   Bound    pvc-e7c1f218-f2f7-4ca5-a031-fb82bd1c1818   64Gi       RWO            local-path     2m9s   File
system
```
