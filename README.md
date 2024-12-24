# Vagrant Kubernetes
This project sets up a Kubernetes (K8s) cluster either in a group of Vagrant boxes (which it sets up itself) or on a named set of nodes (which have to be set up by the user) using Kubespray.

## Overview
The main script `Make_Kubernetes.sh` orchestrates the entire setup process and supports both modes. It accepts the following commands:

- **UP_ONLY**: Brings up the Vagrant nodes and provisions them, where `--location vagrant` is used. Mandatory in this case.
- **SKIP_UP**: Skips bringing up the Vagrant nodes and proceeds directly to deploying kubernetes on them (assumes nodes are already up). Optional if `--location physical` specified, otherwise mandatory.

### Usage
To set up everything, run the `Make_Kubernetes.sh` script. 

First run with UP_ONLY argument to create the machines in vagrant:

```
./Make_kubernetes.sh --location vagrant UP_ONLY
```
Wait until you see the message Script Vagrant_Kubernetes_Setup.sh has finished in the log file.

Now run with SKIP_UP argument to deploy the kubernetes cluster:

```
./Make_Kubernetes.sh --location vagrant SKIP_UP
```

if  you are making a virtual cluster, or if you want a phyical cluster:

```
./Make_Kubernetes.sh --location physical SKIP_UP
```

Access the first control node using something like:

```
vagrant ssh node1
```

(depending on what you have set node_name to in config.json).

When finished, destroy the Kubernetes cluster with:

```
vagrant destroy -f
```

(or a hammer and an angle grinder if you made a physical cluster).

### Configuration
The cluster settings are defined in config.json. This file specifies:

- **kube_version**: The version of Kubernetes to install.
- **kubespray_version**: The Git commit hash or tag of Kubespray to use.
- **control_nodes**: Number of control plane nodes (default: 1).
- **worker_nodes**: Number of worker nodes (default: 1).
- **ram_size**: RAM size for each node in MB (default: 2048).
- **cpu_count**: CPU count for each node (default: 2).
- **pub_net**: Public network base IP (default: "192.168.56"). Only made use of by vagrant.
- **node_name**: Name prefix of the nodes. Will be set and used by vagrant, but just used for physical.
- **kube_network_plugin**: "cilium" or `calicon`
- **box_name**: "bento/ubuntu-22.04". Name of vagrant box when location is vagrant.

Example config.json
```
{
  "kube_version": "v1.31.3",
  "control_nodes": 1,
  "worker_nodes": 1,
  "ram_size": 8196,
  "cpu_count" : 4,
  "pub_net": "192.168.56",
  "node_name": "machine",
  "kube_network_plugin": "cilium",
  "box_name": "bento/ubuntu-22.04"
}
```

### Details
The Vagrantfile is created from a Vagrantfile.template. It only includes base definitions of the boxes. Provisioning (like update, upgrades and installs of dependencies) is done by the `Make_Kubernetes.sh` script..
It automatically selects an arm64 image if running on an arm64 platform (e.g., Apple Silicon Macs), or an x86 image otherwise.
The `Make_Kubernetessh` script uses the Vagrant insecure private key (~/.vagrant.d/insecure_private_key) to allow SSH into all the nodes.
Before executing Kubespray on the first node, the script ensures SSH access is set up from node1 to all other nodes.

### Notes
Ensure you have Vagrant and VirtualBox installed (unless only doing physical)

The setup process can take some time depending on your system's performance and network speed.

![Kubernetes Diagram](./diagrams/k8s.png)

### Troubleshooting
- **SSH Issues**: If node1 cannot SSH into other nodes, ensure that the insecure private key is correctly uploaded and that SSH keys are properly configured.
- **Vagrant Errors**: If you encounter issues during vagrant up, try running vagrant reload or check the Vagrant logs for more details.
- **Kubespray Errors**: Consult the Kubespray documentation and logs if the Kubernetes cluster fails to deploy.

### Acknowledgments
This project utilizes Kubespray for deploying Kubernetes.
Vagrant boxes are based on Ubuntu images. You can specify your own flavour, but expect fun and games.
