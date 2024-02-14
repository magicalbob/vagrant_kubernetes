#!/usr/bin/env bash

# Required Environment Variables
if [ -z "$REDIS_IP" ]
then
  echo "Environment variable REDIS_IP has to be provided"
  exit 1
fi

if [ -z "$REDIS_PASSWORD" ]
then
  echo "Environment variable REDIS_PASSWORD has to be provided"
  exit 1
fi

if [ -z "$SSH_PUBLIC" ]
then
  echo "Environment variable SSH_PUBLIC has to be provided"
  exit 1
fi

if [ ! -f "$SSH_PUBLIC" ]
then
  echo "Public key given does not exist"
  exit 1
fi

export SSH_PUBLIC_CONTENT=$(cat $SSH_PUBLIC)

# Read configuration from config.json
CONTROL_NODES=$(jq -r '.control_nodes' config.json)
WORKER_NODES=$(jq -r '.worker_nodes' config.json)
export TOTAL_NODES=$((CONTROL_NODES + WORKER_NODES))
export RAM_SIZE=$(jq -r '.ram_size' config.json)
export CPU_COUNT=$(jq -r '.cpu_count' config.json)
export PUB_NET=$(jq -r '.pub_net' config.json)
export KUBE_VERSION=$(jq -r '.kube_version' config.json)

echo Work out primary network adapter for Mac or linux
if [[ $(uname) == "Darwin" ]]; then
  # For macOS
  PRIMARY_ADAPTER=$(route get default | grep interface | awk '{print $2}')
elif [[ $(uname) == "Linux" ]]; then
  # For Linux
  PRIMARY_ADAPTER=$(ip route get 1 | awk '{print $5; exit}')
fi
echo "Primary Adapter: ${PRIMARY_ADAPTER}"
export PRIMARY_ADAPTER

echo Create Vagrantfile from template
envsubst < Vagrantfile.template > Vagrantfile

echo Bring up all the nodes without provisioning
vagrant up --no-provision

echo Loop to check if all nodes are created and then provision
while vagrant status | grep -q "not created (virtualbox)"; do
  echo "Not all nodes are created yet. Retrying..."
  vagrant up --no-provision
done

echo Provision all the nodes
vagrant provision

echo "Script `basename $0` has finished"
