#!/usr/bin/env bash

# Read configuration from config.json
CONTROL_NODES=$(jq -r '.control_nodes' config.json)
WORKER_NODES=$(jq -r '.worker_nodes' config.json)
export TOTAL_NODES=$((CONTROL_NODES + WORKER_NODES))

# Create Vagrantfile from template
envsubst < Vagrantfile.template > Vagrantfile

# Bring up all the nodes
vagrant up

# Generate the hosts.yaml content
HOSTS_YAML="all:
  hosts:"

for i in $(seq 1 $TOTAL_NODES); do
  HOSTS_YAML+="
    node$i:
      ansible_host: 192.168.200.20$i
      ip: 192.168.200.20$i
      access_ip: 192.168.200.20$i"
done

HOSTS_YAML+="
  children:
    kube_control_plane:
      hosts:"

for i in $(seq 1 $TOTAL_NODES); do
  HOSTS_YAML+="
        node$i:"
done

HOSTS_YAML+="
    kube_node:
      hosts:"

for i in $(seq $((TOTAL_NODES + 1)) $((2 * TOTAL_NODES))); do
  HOSTS_YAML+="
        node$i:"
done

HOSTS_YAML+="
    etcd:
      hosts:"
for i in $(seq 1 $TOTAL_NODES); do
  HOSTS_YAML+="
        node$i:"
done

HOSTS_YAML+="
    k8s_cluster:
      children:
        kube_control_plane:"
for i in $(seq 1 $TOTAL_NODES); do
  HOSTS_YAML+="
        node$i:"
done

HOSTS_YAML+="
        kube_node:"
for i in $(seq $((TOTAL_NODES + 1)) $((2 * TOTAL_NODES))); do
  HOSTS_YAML+="
        node$i:"
done

HOSTS_YAML+="
    calico_rr:
      hosts: {}"

# Write the hosts.yaml content to the file
echo "$HOSTS_YAML" > hosts.yaml

# Set up ssh between the nodes
# First copy the insecure_private_key to node1 (which is the only node that needs it)
vagrant upload ~/.vagrant.d/insecure_private_key /home/vagrant/.ssh/id_rsa node1

# Now create the public key from it
ssh-keygen -y -f ~/.vagrant.d/insecure_private_key > ./insecure_public_key

# Copy the public key to each node
for i in $(seq 1 $TOTAL_NODES); do
  vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node$i
done

# Append the public key to the authorized_keys file on each node
for i in $(seq 1 $TOTAL_NODES); do
  vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node$i
done

# Do an intial ssh to each node (including node1) from node1 
for i in $(seq 1 $TOTAL_NODES); do
  vagrant ssh -c "echo uptime|ssh -o StrictHostKeyChecking=no 192.168.200.20${i}" node1
done

# Clone the project to do the actual kubernetes cluster setup
vagrant ssh -c 'rm -rf /home/vagrant/kubespray' node1
vagrant ssh -c 'git clone https://github.com/kubernetes-sigs/kubespray.git /home/vagrant/kubespray' node1

# Python requirements
vagrant ssh -c 'sudo DEBIAN_FRONTEND=noninteractive apt-get -y install python3.10-venv' node1
vagrant ssh -c 'python3 -m venv /home/vagrant/.py3kubespray'  node1
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && pip install -r /home/vagrant/kubespray/requirements.txt'  node1

# Set up the cluster
vagrant ssh -c 'cp -rfp /home/vagrant/kubespray/inventory/sample /home/vagrant/kubespray/inventory/vagrant_kubernetes' node1
vagrant ssh -c 'declare -a IPS=(192.168.200.201 192.168.200.202 192.168.200.203 192.168.200.204 192.168.200.205 192.168.200.206) && . /home/vagrant/.py3kubespray/bin/activate && CONFIG_FILE=/home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml python3 /home/vagrant/kubespray/contrib/inventory_builder/inventory.py ${IPS[@]}' node1
vagrant ssh -c 'cp /vagrant/hosts.yaml /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml' node1
vagrant ssh -c 'cp /vagrant/addons.yml /home/vagrant/kubespray/inventory/vagrant_kubernetes/group_vars/k8s_cluster/addons.yml' node1

# Disable firewalls, enable IPv4 forwarding and switch off swap
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && ansible all -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml -m shell -a "sudo systemctl stop firewalld && sudo systemctl disable firewalld"' node1
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && ansible all -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml -m shell -a "echo net.ipv4.ip_forward=1 | sudo tee -a /etc/sysctl.conf"' node1
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && ansible all -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml -m shell -a "sudo sed -i \"/ swap / s/^\(.*\)$/#\1/g\" /etc/fstab && sudo swapoff -a"' node1

# Do install of kubernetes
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && cd /home/vagrant/kubespray && ansible-playbook -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml --become --become-user=root /home/vagrant/kubespray/cluster.yml' node1

# Now copy /root/.kube/config to vagrant user
vagrant ssh -c 'mkdir -p /home/vagrant/.kube' node1
vagrant ssh -c 'sudo cp /root/.kube/config /home/vagrant/.kube/config' node1
vagrant ssh -c 'sudo chown vagrant:vagrant /home/vagrant/.kube/config' node1
