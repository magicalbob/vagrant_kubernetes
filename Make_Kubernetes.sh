#!/usr/bin/env bash

# Parse command line arguments
LOCATION=""
UP_ONLY=0
SKIP_UP=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --location)
            LOCATION="$2"
            shift 2
            ;;
        UP_ONLY)
            UP_ONLY=1
            shift
            ;;
        SKIP_UP)
            SKIP_UP=1
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$LOCATION" ]]; then
    echo "Error: --location {vagrant|physical} is required"
    exit 1
fi

if [[ "$LOCATION" != "vagrant" && "$LOCATION" != "physical" ]]; then
    echo "Error: --location must be either 'vagrant' or 'physical'"
    exit 1
fi

if [[ "$LOCATION" == "physical" && $UP_ONLY -eq 1 ]]; then
    echo "Error: UP_ONLY is only supported with --location vagrant"
    exit 1
fi

# Common configuration
cp ~/.vagrant.d/insecure_private_key ./insecure_private_key
echo Work out primary network adapter for Mac or linux

echo "Read configuration from config.json"
CONTROL_NODES=$(jq -r '.control_nodes' config.json)
WORKER_NODES=$(jq -r '.worker_nodes' config.json)
TOTAL_NODES=$((CONTROL_NODES + WORKER_NODES))
RAM_SIZE=$(jq -r '.ram_size' config.json)
CPU_COUNT=$(jq -r '.cpu_count' config.json)
PUB_NET=$(jq -r '.pub_net' config.json)
KUBE_VERSION=$(jq -r '.kube_version' config.json)
KUBESPRAY_VERSION=$(jq -r '.kubespray_version' config.json)
NODE_NAME=$(jq -r '.node_name' config.json)
KUBE_NETWORK_PLUGIN=$(jq -r '.kube_network_plugin // "calico"' config.json)
# Export variables
export CONTROL_NODE WORKER_NODES TOTAL_NODES RAM_SIZE CPU_COUNT PUB_NET KUBE_VERSION KUBESPRAY_VERSION NODE_NAME KUBE_NETWORK_PLUGIN

if [[ "$LOCATION" == "vagrant" ]]; then
    if [[ $(uname) == "Darwin" ]]; then
      # For macOS
      PRIMARY_ADAPTER=$(route get default | grep interface | awk '{print $2}')
    elif [[ $(uname) == "Linux" ]]; then
      # For Linux
      PRIMARY_ADAPTER=$(ip route get 1 | awk '{print $5; exit}')
    fi
    echo "Primary Adapter: ${PRIMARY_ADAPTER}"
    export PRIMARY_ADAPTER
    echo "Create Vagrantfile from template"
    envsubst < Vagrantfile.template > Vagrantfile

    if [ $SKIP_UP -eq 1 ]; then
        echo "Skipping upping and provisioning"
    else
        if [ $UP_ONLY -eq 1 ]; then
            echo "Bring up all the nodes without provisioning"
            vagrant up --no-provision

            echo "Loop to check if all nodes are created and then provision"
            while vagrant status | grep -q "not created (virtualbox)"; do
                echo "Not all nodes are created yet. Retrying..."
                vagrant up --no-provision
            done

            echo "Update and upgrade each node"
            for i in $(seq 1 $TOTAL_NODES); do
                vagrant ssh -c 'sudo apt-get update' ${NODE_NAME}$i
                vagrant ssh -c 'sudo apt-get upgrade -y' ${NODE_NAME}$i
                vagrant ssh -c 'sudo apt-get install -y net-tools ruby jq' ${NODE_NAME}$i
            done

            echo "Write /etc/hosts file"
            cp hosts.template hosts
            for i in $(seq 1 $TOTAL_NODES); do
                echo ${PUB_NET}.22${i} ${NODE_NAME}${i} >> hosts
            done

            echo "Copy hosts file to each node"
            for i in $(seq 1 $TOTAL_NODES); do
                vagrant ssh -c "sudo cp /vagrant/hosts /etc/hosts" ${NODE_NAME}${i}
            done

            echo "Set up ssh between the nodes"
            vagrant upload ./insecure_private_key /home/vagrant/.ssh/id_rsa ${NODE_NAME}1
            ssh-keygen -y -f ./insecure_private_key > ./insecure_public_key
            for i in $(seq 1 $TOTAL_NODES); do
                vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub ${NODE_NAME}$i
            done
            for i in $(seq 1 $TOTAL_NODES); do
                vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' ${NODE_NAME}$i
            done
            for i in $(seq 1 $TOTAL_NODES); do
                vagrant ssh -c "echo uptime|ssh -o StrictHostKeyChecking=no ${PUB_NET}.22${i}" "${NODE_NAME}1"
            done

            echo "Script $(basename "$0") has finished"
            exit 0
        fi
    fi

    echo "Generate the hosts.yaml content"
    HOSTS_YAML="all:
  hosts:"
    for i in $(seq 1 $TOTAL_NODES); do
        HOSTS_YAML+="
    ${NODE_NAME}$i:
      ansible_host: ${PUB_NET}.22$i
      ip: ${PUB_NET}.22$i
      access_ip: ${PUB_NET}.22$i"
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
        kube_dns_mode: \"coredns\"
        kube_dns_replicas: 2
    calico_rr:
      hosts: {}"

    echo "Write the hosts.yaml content to the file"
    echo "$HOSTS_YAML" > hosts.yaml

    echo "Clone the project to do the actual kubernetes cluster setup"
    vagrant ssh "${NODE_NAME}1" -c '
        MAX_ATTEMPTS=3
        ATTEMPT=1
        while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
            echo "Attempt $ATTEMPT of $MAX_ATTEMPTS"
            if [ ! -d "/home/vagrant/kubespray" ] || [ -z "$(ls -A /home/vagrant/kubespray)" ]; then
                git clone https://github.com/kubernetes-sigs/kubespray.git /home/vagrant/kubespray && break
            else
                echo "Directory exists and is not empty. Removing contents..."
                rm -rf /home/vagrant/kubespray/*
            fi
            ATTEMPT=$((ATTEMPT+1))
            [ $ATTEMPT -le $MAX_ATTEMPTS ] && echo "Retrying in 5 seconds..." && sleep 5
        done
        if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
            echo "Failed to clone repository after $MAX_ATTEMPTS attempts"
            exit 1
        fi
    '
else
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
        kube_dns_mode: \"coredns\"
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
fi

# Common steps for both setups
echo "Set up the cluster"
if [[ "$LOCATION" == "vagrant" ]]; then
    ssh "${NODE_NAME}1" '
        cp -rfp /home/vagrant/kubespray/inventory/sample /home/vagrant/kubespray/inventory/vagrant_kubernetes &&
        cp tmp/hosts.yaml /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml &&
    
        sed -i -E "/^kube_version:/s/.*/kube_version: '$KUBE_VERSION'/" /home/vagrant/kubespray/inventory/vagrant_kubernetes/group_vars/k8s_cluster/k8s-cluster.yml &&
        sed -i -E "/^kube_network_plugin:/s/.*/kube_network_plugin: '$KUBE_NETWORK_PLUGIN'/" /home/vagrant/kubespray/inventory/vagrant_kubernetes/group_vars/k8s_cluster/k8s-cluster.yml
    '
else
    vagrant ssh "${NODE_NAME}1" '
        cp -rfp /home/vagrant/kubespray/inventory/sample /home/vagrant/kubespray/inventory/physical_kubernetes &&
        cp tmp/hosts.yaml /home/vagrant/kubespray/inventory/physical_kubernetes/hosts.yaml &&
    
        sed -i -E "/^kube_version:/s/.*/kube_version: '$KUBE_VERSION'/" /home/vagrant/kubespray/inventory/physical_kubernetes/group_vars/k8s_cluster/k8s-cluster.yml &&
        sed -i -E "/^kube_network_plugin:/s/.*/kube_network_plugin: '$KUBE_NETWORK_PLUGIN'/" /home/vagrant/kubespray/inventory/physical_kubernetes/group_vars/k8s_cluster/k8s-cluster.yml
    '
fi

echo "Disable firewalls, enable IPv4 forwarding, and switch off swap on all nodes"
for i in $(seq 1 $TOTAL_NODES); do
    if [[ "$LOCATION" == "vagrant" ]]; then
        vagrant ssh -c 'sudo systemctl stop firewalld && sudo systemctl disable firewalld &&
            echo net.ipv4.ip_forward=1 | sudo tee -a /etc/sysctl.conf &&
            sudo sed -i "/ swap / s/^\(.*\)$/#\1/g" /etc/fstab &&
            sudo swapoff -a' "${NODE_NAME}$i"
    else
        ssh "${NODE_NAME}$i" '
            sudo systemctl stop firewalld &&
            sudo systemctl disable firewalld &&
            echo net.ipv4.ip_forward=1 | sudo tee -a /etc/sysctl.conf &&
            sudo sed -i "/ swap / s/^\(.*\)$/#\1/g" /etc/fstab &&
            sudo swapoff -a
        '
    fi
done

echo "Run Ansible playbook to install Kubernetes"
if [[ "$LOCATION" == "vagrant" ]]; then
    vagrant ssh "${NODE_NAME}1" '
        . ./.py3kubespray/bin/activate &&
        cd kubespray &&
        ansible-playbook -vi ./inventory/vagrant_kubernetes/hosts.yaml --become --become-user=root cluster.yml
    '
else
    ssh "${NODE_NAME}1" '
        . ./.py3kubespray/bin/activate &&
        cd kubespray &&
        ansible-playbook -vi ./inventory/physical_kubernetes/hosts.yaml --become --become-user=root cluster.yml
    '
fi

echo "Copy Kubernetes configuration to the user"
if [[ "$LOCATION" == "vagrant" ]]; then
    vagrant ssh "${NODE_NAME}1" '
        mkdir -p ./.kube &&
        sudo cp /etc/kubernetes/admin.conf ./.kube/config &&
        sudo chown $(id -u):$(id -g) ./.kube/config
    '
else
    ssh "${NODE_NAME}1" '
        mkdir -p ./.kube &&
        sudo cp /etc/kubernetes/admin.conf ./.kube/config &&
        sudo chown $(id -u):$(id -g) ./.kube/config
    '
fi

echo "Install Helm on the primary node"
if [[ "$LOCATION" == "vagrant" ]]; then
    vagrant ssh -c 'sudo snap install helm --classic' "${NODE_NAME}1"
else
    ssh "${NODE_NAME}1" 'sudo snap install helm --classic'
fi

echo "Install Metrics Server"
if [[ "$LOCATION" == "vagrant" ]]; then
    vagrant ssh -c 'kubectl apply -f https://dev.ellisbs.co.uk/files/components.yaml' "${NODE_NAME}1"
else
    ssh "${NODE_NAME}1" 'kubectl apply -f https://dev.ellisbs.co.uk/files/components.yaml'
fi

if [ ! -z "$OPENAI_API_KEY" ]; then
    echo "Install k8sgpt"
    if [[ "$LOCATION" == "vagrant" ]]; then
        vagrant ssh "${NODE_NAME}1" "
            curl -Lo /tmp/k8sgpt.deb https://github.com/k8sgpt-ai/k8sgpt/releases/download/v0.3.24/k8sgpt_$(uname -m | sed 's/x86_64/amd64/').deb &&
            sudo dpkg -i /tmp/k8sgpt.deb &&
            k8sgpt auth add --backend openai --model gpt-3.5-turbo --password $OPENAI_API_KEY
        "
    else
        ssh "${NODE_NAME}1" "
            curl -Lo /tmp/k8sgpt.deb https://github.com/k8sgpt-ai/k8sgpt/releases/download/v0.3.24/k8sgpt_$(uname -m | sed 's/x86_64/amd64/').deb &&
            sudo dpkg -i /tmp/k8sgpt.deb &&
            k8sgpt auth add --backend openai --model gpt-3.5-turbo --password $OPENAI_API_KEY
        "
    fi
fi

echo "Script $(basename "$0") has finished"
