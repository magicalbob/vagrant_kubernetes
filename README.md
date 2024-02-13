Vagrant_Kubernetes
==================

Sets up a cluster of vagrant nodes, then uses `kubespray` to install a k8s cluster on them.

![Kubernetes Diagram](./diagrams/k8s.png)

Scripts `vagrant_cloud.sh` and `vagrant_k8s.sh` co-odinate eveything.

`vagrant_cloud.sh` creates the instances in Vagrant.

`vagrant_k8s.sh` turns those instances into a kubernetes cluster using `Kubespray`.

Script `run_vagrant_cloud`.sh` runs `vagrant_cloud.sh` as a background job and logs the output to `./vagrant_cloud.log`.

Script `run_vagrant_k8s.sh` does same for `vagrant_k8s.sh`.

To set up the instances run `run_vagrant_cloud.sh`, and wait a while for message `Script vagrant_cloud.sh has finished` to appear in the `vagrant_cloud.log` file.

To set up the kubernetes cluster now run `run_vagrant_k8s.sh`, and wait a while for message `Script vagrant_k8s.sh has finished` to appear in the `vagrant_k8s.log` file.

Now you can run `vagrant ssh node1` to access the 1st control node. When finished (after exiting the node), simply run `vagrant destroy -f` to get rid of the k8s cluster.

![Lower Level Diagram](./diagrams/Lower_Level.png)

The number of control plane nodes (default 1) and worker nodes (default 1) are defined in `config.json`, along with RAM size (default 2048) and cpu counts (default 2) of each node. Each node is the same size for simplicity. `config.json` also defines the version of kubernetes to install on each node.

The Vagrantfile includes a provisioning script that brings each ubuntu node's OS up to date. The Vagrantfile is engineered to use an arm64 image if running on an arm64 platform (like a recent Mac) or x86 otherwise.

The scripts make use of `~/.vagrant.d/insecure_private_key` to allow `node1` to ssh freely to each of the nodes (including itself). Before the script `vagrant_k8s.sh` executes `kubespray` on node1 (that then takes charge of setting up all the nodes in the hosts.yaml), it takes time to ssh to each node from node1. 
