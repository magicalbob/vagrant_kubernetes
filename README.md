# Vagrant Kubernetes
This project sets up a cluster of Vagrant nodes and uses Kubespray to install a Kubernetes (K8s) cluster on them.

## Overview
The main script Vagrant_Kubernetes_Setup.sh orchestrates the entire setup process. It accepts the following commands:

- **UP_ONLY**: Brings up the Vagrant nodes and provisions them.
- **SKIP_UP**: Skips bringing up the Vagrant nodes and proceeds directly to deploying kubernetes on them (assumes nodes are already up).

### Commands
#### UP_ONLY
Brings up all the nodes and runs the provisioning steps to update them.
Useful for setting up the Vagrant environment separately.
#### SKIP_UP
Skips the vagrant up process.
Proceeds with running of ansible kubespray to deploy the kubernetes cluster.
Assumes the Vagrant nodes are already running.
### Usage
To set up everything, run the run_vagrant_kubernetes.sh script. This script runs in the background and logs output to ./vagrant_kubernetes.log.


First run with UP_ONLY argument to create the machines in vagrant:

```
./run_vagrant_kubernetes.sh UP_ONLY
```
Wait until you see the message Script Vagrant_Kubernetes_Setup.sh has finished in the log file.

Now run with SKIP_UP argument to deploy the kubernetes cluster:

```
./run_vagrant_kubernetes.sh SKIP_UP
```

Access the first control node using:

```
vagrant ssh node1
```

When finished, destroy the Kubernetes cluster with:

```
vagrant destroy -f
```

### Configuration
The cluster settings are defined in config.json. This file specifies:

- **kube_version**: The version of Kubernetes to install.
- **kubespray_version**: The Git commit hash or tag of Kubespray to use.
- **control_nodes**: Number of control plane nodes (default: 1).
- **worker_nodes**: Number of worker nodes (default: 1).
- **ram_size**: RAM size for each node in MB (default: 2048).
- **cpu_count**: CPU count for each node (default: 2).
- **pub_net**: Public network base IP (default: "192.168.56").

Example config.json
```
{
  "kube_version": "v1.30.2",
  "kubespray_version": "1ebd860c13d95e7f19dd12f1fd9fa316cb0f9740",
  "control_nodes": 1,
  "worker_nodes": 1,
  "ram_size": 2048,
  "cpu_count": 2,
  "pub_net": "192.168.56"
}
```
### Details
The Vagrantfile includes a provisioning script that updates each Ubuntu node.
It automatically selects an arm64 image if running on an arm64 platform (e.g., Apple Silicon Macs), or an x86 image otherwise.
The Vagrant_Kubernetes_Setup.sh script uses the Vagrant insecure private key (~/.vagrant.d/insecure_private_key) to allow node1 to SSH into all nodes, including itself.
Before executing Kubespray on node1, the script ensures SSH access is set up from node1 to all other nodes.

### Notes
Ensure you have Vagrant and VirtualBox installed.

The script may need execution permissions:

```
chmod +x Vagrant_Kubernetes_Setup.sh
```

The setup process can take some time depending on your system's performance and network speed.

![Kubernetes Diagram](./diagrams/k8s.png)

### Troubleshooting
- **SSH Issues**: If node1 cannot SSH into other nodes, ensure that the insecure private key is correctly uploaded and that SSH keys are properly configured.
- **Vagrant Errors**: If you encounter issues during vagrant up, try running vagrant reload or check the Vagrant logs for more details.
- **Kubespray Errors**: Consult the Kubespray documentation and logs if the Kubernetes cluster fails to deploy.

### Acknowledgments
This project utilizes Kubespray for deploying Kubernetes.
Vagrant boxes are based on Ubuntu images.
