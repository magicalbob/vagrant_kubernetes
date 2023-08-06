#!/usr/bin/env bash

# Bring up all the nodes
vagrant up

# Set up ssh from node 1 to nodes 1 through 5
./setup_ssh.sh

# Clone the project to do the actual kubernetes cluster setup
vagrant ssh -c 'rm -rf /home/vagrant/kubespray' node1
vagrant ssh -c 'git clone https://github.com/kubernetes-sigs/kubespray.git /home/vagrant/kubespray' node1

# Python requirements
vagrant ssh -c 'sudo DEBIAN_FRONTEND=noninteractive apt-get -y install python3.10-venv' node1
vagrant ssh -c 'python3 -m venv /home/vagrant/.py3kubespray'  node1
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && pip install -r /home/vagrant/kubespray/requirements.txt'  node1

# Set up the cluster
vagrant ssh -c 'cp -rfp /home/vagrant/kubespray/inventory/sample /home/vagrant/kubespray/inventory/vagrant_kubernetes' node1
vagrant ssh -c 'declare -a IPS=(192.168.200.201 192.168.200.202 192.168.200.203 192.168.200.204 192.168.200.205) && . /home/vagrant/.py3kubespray/bin/activate && CONFIG_FILE=/home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml python3 /home/vagrant/kubespray/contrib/inventory_builder/inventory.py ${IPS[@]}' node1
vagrant ssh -c 'cp /vagrant/hosts.yaml /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml' node1
