Vagrant_Kubernetes
==================

Sets up a cluster of vagrant nodes, then uses `kubespray` to install a k8s cluster on them.

Scripts `Vagrant_Kubernetes_Setup.sh` co-odinates eveything.

Just use `vagrant destroy -f` once you're finished with the cluster.

By default there are 5 instances in the cluster, 3 in the control plane and 2 worker nodes. Each instance has 2 CPUs and 2GB RAM. 

`Vagrant_Kubernetes_Setup.sh` makes use of `~/.vagrant.d/insecure_private_key` to allow `node1` to ssh freely to each of the nodes (including itself). 
