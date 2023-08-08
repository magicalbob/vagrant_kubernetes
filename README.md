Vagrant_Kubernetes
==================

Sets up a cluster of vagrant nodes, then uses `kubespray` to install a k8s cluster on them.

Scripts `Vagrant_Kubernetes_Setup.sh` co-odinates eveything.

Just use `vagrant destroy -f` once you're finished with the cluster.

By default there are 2 instances in the cluster, 1 in the control plane and 1 worker node. Each instance has 4 CPUs and 8GB RAM. The number of control plane nodes and worker nodes are defined in `config.json`.

`Vagrant_Kubernetes_Setup.sh` makes use of `~/.vagrant.d/insecure_private_key` to allow `node1` to ssh freely to each of the nodes (including itself). 
