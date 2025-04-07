#!/bin/bash
# Script to run Kubernetes cluster validation

# Extract node name from config
NODE_NAME=$(jq -r .node_name config.json)1
echo "Running validation on node: $NODE_NAME"

# Run validation script on the first node
vagrant ssh -c "ruby /vagrant/validate_cluster.rb|tee /vagrant/validate_cluster.log" $NODE_NAME

# Exit with the exit code of the last command
exit $?
