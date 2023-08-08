Vagrant_Kubernetes
==================

Sets up a cluster of vagrant nodes, then uses `kubespray` to install a k8s cluster on them.

Script `Vagrant_Kubernetes_Setup.sh` co-odinates eveything. Script `run_vagrant_kubernetes.sh` it as a background job and logs the output to `./vagrant_kubernetes.log`.

Just use `vagrant destroy -f` once you're finished with the cluster.

The number of control plane nodes (default 1) and worker nodes (default 1) are defined in `config.json`, along with RAM size (default 2048) and cpu counts (default 2). Each node is the same size.

`Vagrant_Kubernetes_Setup.sh` makes use of `~/.vagrant.d/insecure_private_key` to allow `node1` to ssh freely to each of the nodes (including itself). 
