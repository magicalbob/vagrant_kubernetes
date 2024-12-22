#!/usr/bin/env bash

# Check for SKIP_UP argument
if [[ "$1" == "SKIP_UP" ]]; then
  export SKIP_UP=1
else
  echo "This script only supports SKIP_UP mode."
  exit 1
fi

echo "Read configuration from config.json"
CONTROL_NODES=$(jq -r '.control_nodes' config.json)
WORKER_NODES=$(jq -r '.worker_nodes' config.json)
export TOTAL_NODES=$((CONTROL_NODES + WORKER_NODES))
export KUBE_VERSION=$(jq -r '.kube_version' config.json)
export KUBESPRAY_VERSION=$(jq -r '.kubespray_version' config.json)
export PUB_NET=$(jq -r '.pub_net' config.json)
export NODE_NAME=$(jq -r '.node_name' config.json)
export KUBE_NETWORK_PLUGIN=$(jq -r '.kube_network_plugin // "calico"' config.json)

echo "Generate the hosts.yaml content"
HOSTS_YAML="all:
  hosts:"

for i in $(seq 1 $TOTAL_NODES); do
  HOST_IP=$(ping -c1 ${NODE_NAME}$i|head -1|cut -d\( -f2|cut -d\) -f1)
  HOSTS_YAML+="
    ${NODE_NAME}$i:
      ansible_host: ${HOST_IP}
      ip: ${HOST_IP}
      access_ip: ${HOST_IP}"
done

HOSTS_YAML+="
  children:
    kube_control_plane:
      hosts:"

for i in $(seq 1 $CONTROL_NODES); do
  HOSTS_YAML+="
        ${NODE_NAME}$i:"
done

HOSTS_YAML+="
    kube_node:
      hosts:"

for i in $(seq $((CONTROL_NODES + 1)) $((TOTAL_NODES))); do
  HOSTS_YAML+="
        ${NODE_NAME}$i:"
done

HOSTS_YAML+="
    etcd:
      hosts:"
for i in $(seq 1 $CONTROL_NODES); do
  HOSTS_YAML+="
        ${NODE_NAME}$i:"
done

HOSTS_YAML+="
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    kube_dns:
      vars:
        kube_dns_mode: "coredns"
        kube_dns_replicas: 2
    calico_rr:
      hosts: {}"

echo "Write the hosts.yaml content to the file"
echo "$HOSTS_YAML" > hosts.yaml

echo "Transfer required files to the primary control node"
scp -o StrictHostKeyChecking=no config.json hosts.yaml "${NODE_NAME}1:tmp/"

echo "Clone the kubespray repository on the primary control node"
ssh -o StrictHostKeyChecking=no "${NODE_NAME}1" '
    MAX_ATTEMPTS=3
    ATTEMPT=1
    while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        echo "Attempt $ATTEMPT of $MAX_ATTEMPTS"
        if [ ! -d "./kubespray" ] || [ -z "$(ls -A ./kubespray)" ]; then
            git clone https://github.com/kubernetes-sigs/kubespray.git /home/vagrant/kubespray && break
        else
            echo "Directory exists and is not empty. Removing contents..."
            rm -rf ./kubespray
        fi
        ATTEMPT=$((ATTEMPT+1))
        [ $ATTEMPT -le $MAX_ATTEMPTS ] && echo "Retrying in 5 seconds..." && sleep 5
    done
    if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
        echo "Failed to clone repository after $MAX_ATTEMPTS attempts"
        exit 1
    fi
'

if [ ! -z "$KUBESPRAY_VERSION" ] && [ "$KUBESPRAY_VERSION" != "null" ]; then
    echo "Checkout tag $KUBESPRAY_VERSION"
    ssh "${NODE_NAME}1" "cd ./kubespray && git checkout $KUBESPRAY_VERSION"
fi

echo "Install Python and dependencies on all nodes"
for i in $(seq 1 $TOTAL_NODES); do
    ssh "${NODE_NAME}$i" 'sudo apt-get update && sudo apt-get install -y python3 python3-venv'
done

ssh "${NODE_NAME}1" '
    python3 -m venv ./.py3kubespray &&
    . ./.py3kubespray/bin/activate &&
    pip install -r ./kubespray/requirements.txt
'

echo "Set up the cluster"
ssh "${NODE_NAME}1" '
    cp -rfp kubespray/inventory/sample kubespray/inventory/physical_kubernetes &&
    cp tmp/hosts.yaml ./kubespray/inventory/physical_kubernetes/hosts.yaml &&

    # Update kube_version in k8s-cluster.yml
    sed -i -E "/^kube_version:/s/.*/kube_version: '$KUBE_VERSION'/" kubespray/inventory/physical_kubernetes/group_vars/k8s_cluster/k8s-cluster.yml &&

    # Update kube_network_plugin in k8s-cluster.yml
    sed -i -E "/^kube_network_plugin:/s/.*/kube_network_plugin: '$KUBE_NETWORK_PLUGIN'/" kubespray/inventory/physical_kubernetes/group_vars/k8s_cluster/k8s-cluster.yml
'

echo "Cluster setup with kube_network_plugin set to $KUBE_NETWORK_PLUGIN"

echo "Disable firewalls, enable IPv4 forwarding, and switch off swap on all nodes"
for i in $(seq 1 $TOTAL_NODES); do
    ssh "${NODE_NAME}$i" '
        sudo systemctl stop firewalld &&
        sudo systemctl disable firewalld &&
        echo net.ipv4.ip_forward=1 | sudo tee -a /etc/sysctl.conf &&
        sudo sed -i "/ swap / s/^\(.*\)$/#\1/g" /etc/fstab &&
        sudo swapoff -a
    '
done

scp addons.yml "${NODE_NAME}1:kubespray/inventory/physical_kubernetes/group_vars/k8s_cluster/addons.yml"

echo "Uncomment upstream dns servers in all.yaml"
ssh "${NODE_NAME}1" 'sed -i "/upstream_dns_servers:/s/^# *//" ~/kubespray/inventory/physical_kubernetes/group_vars/all/all.yml'
ssh "${NODE_NAME}1" 'sed -i "/- 8.8.8.8/s/^# *//" ~/kubespray/inventory/physical_kubernetes/group_vars/all/all.yml'
ssh "${NODE_NAME}1" 'sed -i "/- 8.8.4.4/s/^# *//" ~/kubespray/inventory/physical_kubernetes/group_vars/all/all.yml'

echo "Run Ansible playbook to install Kubernetes"
ssh "${NODE_NAME}1" '
    . ./.py3kubespray/bin/activate &&
    cd kubespray &&
    ansible-playbook -vi ./inventory/physical_kubernetes/hosts.yaml --become --become-user=root cluster.yml
'

echo "Copy Kubernetes configuration to the user"
ssh "${NODE_NAME}1" '
    mkdir -p ./.kube &&
    sudo cp /etc/kubernetes/admin.conf ./.kube/config &&
    sudo chown $(id -u):$(id -g) ./.kube/config
'

echo "Install Helm on the primary node"
ssh "${NODE_NAME}1" 'sudo snap install helm --classic'

echo "Script $(basename "$0") has finished"
