# Integrating Scientific GUI Applications into Autoscaled Science Gateway Environments

Companion code for Gateways 2025 paper on autoscaled scientific GUI desktops.
The documentation found in this README is meant for demonstrative purposes and
*not* intended for use in production. In particular, the authentication
mechanism uses a single shared password for all admin users and a different
single shared password for all "regular" users. In addition, the included
JupyterHub configuration does not include any persistent storage.

The initial deployment of the Kubernetes (K8s) cluster is based off of Andrea
Zonca's [blog
post](https://www.zonca.dev/posts/2024-12-11-jetstream_kubernetes_magnum) on
this matter, which has since been incorporated as part of the official
[Jetstream2
documentation](https://docs.jetstream-cloud.org/general/k8smagnum/?h=magnum).

# Abstract

We present an application of a new capability on the NSF Jetstream2 cloud that
enables scalable access to established scientific desktop applications in the
atmospheric sciences, including the Unidata Integrated Data Viewer (IDV), the
AWIPS CAVE client, and the LROSE Hawkeye tool. By leveraging OpenStack Magnum’s
Kubernetes autoscaling clusters-as-a-service, in combination with JupyterHub
and VNC technology, the NSF Unidata Science Gateway dynamically provisions
server resources to meet user demand, allowing these desktop applications to
run efficiently in a cloud environment. This approach makes it feasible to
support resource-intensive GUI tools in scenarios where static provisioning
would otherwise be cost-prohibitive or technically infeasible. We describe our
deployment strategy, emphasizing that this model offers a practical workflow
for integrating traditional desktop applications with modern gateway features
such as computational notebooks and may be applicable to other domains
requiring similar capabilities.

# Table of Contents

- [Abstract](#Abstract)
- [Table of Contents](#Table-of-Contents)
- [How To](#How-To)
  - [Prerequisites](#Prerequisites)
  - [Provision a Cluster with Magnum](#Provision-a-Cluster-with-Magnum)
    - [Create the Cluster](#Create-the-Cluster)
    - [Fetch the kubectl config file](#Fetch-the-kubectl-config-file)
    - [Label the default worker node](#Label-the-default-worker-node)
    - [Configure a Subdomain](#Configure-a-Subdomain)
    - [Install an Ingress Resource](#Install-an-Ingress-Resource)
    - [Configure HTTPS](#Configure-HTTPS)
    - [Create a Nodegroup](#Create-a-Nodegroup)
  - [Install JupyterHub](#Install-JupyterHub)
    - [Build the Docker Images (Optional)](#Build-the-Docker-Images-Optional)
    - [Deploy JupyterHub via Helm](#Deploy-JupyterHub-via-Helm)
  - [Cluster Teardown](#Cluster-Teardown)

# How To

[To Table of Contents](#Table-of-Contents)

## Prerequisites

[To Table of Contents](#Table-of-Contents)

Before proceeding, you must:

1) Have an allocation on the Jetstream2 Cloud

1) Install python dependencies 
`pip install -r requirements.txt`

1) Generate an [Application
Credential](https://docs.jetstream-cloud.org/ui/cli/auth/)
   - Be sure to check the "Unrestricted" box, as Magnum needs certain
     permissions granted by this option to operate properly

1) Install the K8s API CLI
interface[kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) and the K8s
package manager [helm](https://helm.sh/docs/intro/install/)
   - This project was tested using `kubectl` version `1.26` and `helm` version
     `3.8.1`

1) Install `git` on your system and clone Andrea Zonca's repository, as it
contains several convenience scripts: 
`git clone https://github.com/zonca/jupyterhub-deploy-kubernetes-jetstream`

1) Have a Docker registry you can push to, e.g. DockerHub
   - This prerequisite is optional and only necessary if you wish to supply your
     own images, or modify the ones we provide with this repo

## Provision a Cluster with Magnum

[To Table of Contents](#Table-of-Contents)

### Create the Cluster

[To Table of Contents](#Table-of-Contents)

Creating a Kubernetes cluster is made simple with Openstack Magnum, and is made
even simpler with Andrea's convenience scripts. The `create_cluster.sh` script
has some default values that we wish to overwrite. Using your favorite text
editor, overwrite the following default values:

```bash
cd jupyterhub-deploy-kubernetes-jetstream/kubernetes_magnum
vim create_cluster.sh
```

```bash
# In create_cluster.sh

# We can override the default values of the template
FLAVOR="m3.quad" # Default: "m3.small"
TEMPLATE="kubernetes-1-30-jammy"
AUTOSCALING=true
MASTER_FLAVOR=$FLAVOR
DOCKER_VOLUME_SIZE_GB=10

# Number of instances
N_MASTER=1 # Needs to be odd # Default: 3
N_NODES=1
```

We keep the number of worker nodes `N_NODES` equal to 1, as we will be creating
a "NodeGroup" on which we'll schedule single user JupyterLab servers.

Now, export your cluster name and run `create_cluster.sh`. The script will
periodically output the cluster creation status. Cluster creation should take
approximately 10 minutes.

```bash
export K8S_CLUSTER_NAME="gw25"
bash create_cluster.sh
```

Once cluster creation has completed, you should be able to see the `gw25`
cluster by executing the following command:

`openstack coe cluster list`

### Fetch the kubectl config File

[To Table of Contents](#Table-of-Contents)

The `kubectl` `config` file will allow `kubectl` to interact with the K8s API on
your newly created cluster. Take caution when running the following commands if
you already have a `~/.kube/config` file from another cluster, as it will be
overwritten:

```bash
openstack coe cluster config $CLUSTER --force
chmod 600 config
mkdir -p ~/.kube/
mv config ~/.kube/config
```

You should now be able to run `kubectl` commands, such as `kubectl get nodes`.

### Label the default worker node

[To Table of Contents](#Table-of-Contents)

We will add a label to the default worker node to ensure that JupyterHub "core"
Pods, which are essential to a healthy JupyterHub cluster, are isolated from the
resource hungry single user JupyterLab servers.

```bash
kubectl get nodes
# Take note of the name of the default-worker node
kubectl label nodes <default-worker-node-name> hub.jupyter.org/node-purpose=core
```

This label is referenced in the JupyterHub configuration `values.yaml`.

### Install an Ingress Resource

[To Table of Contents](#Table-of-Contents)

A Kubernetes "Ingress" allows traffic into the cluster and is necessary to
configure HTTPS. The following `helm` command will install
[ingress-nginx](https://github.com/kubernetes/ingress-nginx) in a new namespace
and will ensure that the ingress Pods will be scheduled exclusively on nodes of
the `default-worker` nodegroup (which is always created with the cluster):

```bash
helm upgrade --install ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set 'controller.nodeSelector.capi\.stackhpc\.com/node-group=default-worker'
```

After a short while, you should see the ingress Service resource when you run
this command:

`kubectl get svc -n ingress-nginx`

Take note of the `EXTERNAL-IP` of the `ingress-nginx-controller` Service, as
this will be used to create an "A record" and allow users to access the
JupyterHub.

### Configure a Subdomain

[To Table of Contents](#Table-of-Contents)

To create an "A record", that is a subdomain name, for your cluster, we first
need to find your project's "zone":

```bash
openstack zone list
```

This should return something that looks like
`<project-id>.projects.jetstream-cloud.org.`. The period `.` immediately
following `org` is relevant.

Create an A record in this zone, where `<EXTERNAL_IP>` is the IP you noted when
you created the ingress resource above:

```bash
openstack recordset create \
  <project-id>.projects.jetstream-cloud.org. \
  $K8S_CLUSTER_NAME \
  --type A \
  --record <EXTERNAL-IP> \
  --ttl 3600
```

You should now be able to access
`$K8S_CLUSTER_NAME.<project-id>.projects.jetstream-cloud.org` in your web
browser. However, at this stage, you will only see a blank `nginx` page as we
haven't set up any services yet.

### Configure HTTPS

[To Table of Contents](#Table-of-Contents)

We will use `cert-manager` to obtain a certificate from LetsEncrypt, which will
allow for secure connections to JupyterHub via HTTPS.

Navigate to `~/jupyterhub-deploy-kubernetes-jetstream/setup_https`.

Edit `https_cluster_issuer.yaml` to include your email address.

Deploy the cert manager Pods by applying the manifest from GitHub:

`kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml`

Apply the cluster issuer manifest:

`kubectl apply -f https_cluster_issuer.yml`

Your cluster should now be ready to request and obtain a certificate.

### Create a Nodegroup

[To Table of Contents](#Table-of-Contents)

As mentioned in a previous section, we created the cluster with a single worker
node. Here, we create a new "nodegroup" on which we'll schedule the JupyterHub
singleuser servers, the user-facing portion of the science gateway.

With this command, you will create an auto-scaling nodegroup named `mediums`
that can grow to a maximum of 20 `m3.medium` nodes.

```bash
openstack coe nodegroup create $K8S_CLUSTER_NAME mediums \
    --node-count 1 \
    --flavor m3.medium \
    --labels auto_scaling_enabled=true \
    --min-nodes 1 \
    --max-nodes 20
```

After a short amount of time, about 5 minutes, you should see the new node in
the output of `kubectl get nodes`.

## Install JupyterHub

[To Table of Contents](#Table-of-Contents)

### Build the Docker Images (Optional)

[To Table of Contents](#Table-of-Contents)

You may wish to make modifications to the supplied Docker images. You can find
them in this repo under the `docker` directory.

To build the PyAOS (Python for the Atmospheric and Ocean Sciences) JupyterLab
image:

```bash
cd docker/pyaos
docker build --tag <pyaos-image-name:tag> .
```

To build the IDV/AWIPS CAVE sidecar container:

```bash
cd docker/sidecar
docker build --tag <sidecar-image-name:tag> .
```

Push the images to your registry (assumed to be DockerHub) with:

```bash
docker login
docker push <pyaos-image-name:tag>
docker push <sidecar-image-name:tag>
docker logout
```

Finally, to use your images, modify the following keys in `values.yaml`:

```yaml
singleuser:
  ...
  image:
    name: <pyaos-image-name>
    tag: <pyaos-image-tag>
  ...
  profileList:
  ...
    - display_name: "IDV/CAVE"
      ...
      kubespawner_override:
        ...
        extra_containers:
          - name: cave-idv-sidecar
            image: "<sidecar-image-name:tag>"
        ...
```

### Deploy JupyterHub via Helm

[To Table of Contents](#Table-of-Contents)

Before we finally deploy JupyterHub, we need to perform a few last
configurations.

1) Add the JupyterHub `helm` repository by running: 
```bash
helm repo add jupyterhub https://jupyterhub.github.io/helm-chart/
helm repo update
```

1) Dynamically create some secret values in `values.yaml` by running:
```bash
cd gateways2025-cloud-desktop
export INGRESS_HOST="$K8S_CLUSTER_NAME.<project-id>.projects.jetstream-cloud.org"
./create_secrets.sh
```

1) Install JupyterHub by running:
```bash
bash install_jhub.sh
```

The initial deployment may take some time while images are pulled and Pods are
created. You can check the status of the deployment by running: 
`kubectl get pods -n jhub`

You can check the status of the HTTPS certificate by running: 
```bash
kubectl get certificate
kubectl get certificaterequest
```

Inspect `values.yaml` for the username and password to use to login.

## Cluster Teardown

[To Table of Contents](#Table-of-Contents)

Magnum makes tearing down the cluster as simple as it is to create it. We make
use of Andrea's convenience scripts once again:

```bash
echo $K8S_CLUSTER_NAME # Ensure you're deleting the correct cluster
cd ~/jupyterhub-deploy-kubernetes-jetstream/kubernetes_magnum
bash delete_cluster.sh
```

Finally, we delete the A record/subdomain:

```bash
openstack recordset delete \
  <project-id>.projects.jetstream-cloud.org. \
  $K8S_CLUSTER_NAME.<project-id>.projects.jetstream-cloud.org.
```
