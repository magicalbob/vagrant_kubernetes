#!/usr/bin/env bash

# Bring up all the nodes
vagrant up

# Set up ssh from node 1 to nodes 1 through 5
./setup_ssh.sh

# Clone the project to do the actual kubernetes cluster setup
vagrant ssh -c 'git clone https://github.com/kubernetes-sigs/kubespray.git' node1
