#!/usr/bin/env bash

# Bring up all the nodes
vagrant up

# Set up ssh from node 1 to nodes 1 through 5
./setup_ssh.sh
