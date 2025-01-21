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

# Validate arguments
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

# Helper functions
run_on_node() {
    local node="$1"
    local cmd="$2"
    if [[ "$LOCATION" == "vagrant" ]]; then
        vagrant ssh -c "$cmd" "$node"
    else
        ssh -o StrictHostKeyChecking=no "$node" "$cmd"
    fi
}

copy_to_node() {
    local src="$1"
    local dest="$2"
    local node="$3"
    if [[ "$LOCATION" == "vagrant" ]]; then
        vagrant upload "$src" "$dest" "$node"
    else
        scp -o StrictHostKeyChecking=no "$src" "${node}:${dest}"
    fi
}

# Common configuration
cp ~/.vagrant.d/insecure_private_key ./insecure_private_key

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
BOX_NAME=$(jq -r '.box_name // "bento/ubuntu-22.04"' config.json)
DISK_SIZE=$(jq -r '.disk_size // "51200"' config.json)
MAC_ADDRESS=$(jq -r '.mac_address // "08:00:aa:aa:aa:aa" | gsub(":"; "")' config.json)


# Export variables
export CONTROL_NODES WORKER_NODES TOTAL_NODES RAM_SIZE CPU_COUNT PUB_NET KUBE_VERSION KUBESPRAY_VERSION NODE_NAME KUBE_NETWORK_PLUGIN BOX_NAME DISK_SIZE MAC_ADDRESS

# Vagrant-specific setup
if [[ "$LOCATION" == "vagrant" ]]; then
    echo "Install vagrant plugin for disk size"
    vagrant plugin install vagrant-disksize

    echo "Work out primary network adapter for Mac or linux"
    if [[ $(uname) == "Darwin" ]]; then
        PRIMARY_ADAPTER=$(route get default | grep interface | awk '{print $2}')
    elif [[ $(uname) == "Linux" ]]; then
        PRIMARY_ADAPTER=$(ip route get 1 | awk '{print $5; exit}')
    fi
    echo "Primary Adapter: ${PRIMARY_ADAPTER}"
    export PRIMARY_ADAPTER
    
    echo "Create Vagrantfile from template"
    envsubst < Vagrantfile.template > Vagrantfile

    if [ $SKIP_UP -eq 0 ] && [ $UP_ONLY -eq 1 ]; then
        echo "Bring up all the nodes without provisioning"
        vagrant up --no-provision

        echo "Loop to check if all nodes are created and then provision"
        while vagrant status | grep -q "not created (virtualbox)"; do
            echo "Not all nodes are created yet. Retrying..."
            vagrant up --no-provision
        done

        echo "Update and upgrade each node"
        for i in $(seq 1 $TOTAL_NODES); do
            for cmd in \
                'sudo pvresize /dev/sda3' \
                'sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv' \
                'sudo resize2fs /dev/ubuntu-vg/ubuntu-lv' \
                'echo "grub-pc grub-pc/install_devices multiselect /dev/sda" | sudo debconf-set-selections' \
                'DEBIAN_FRONTEND=noninteractive sudo apt-get update' \
                'DEBIAN_FRONTEND=noninteractive sudo apt-get upgrade -y' \
                'sudo apt-get install -y net-tools ruby jq chrony' \
                'sudo systemctl enable chrony --now' \
                'sudo chronyc -a makestep'; do
                run_on_node "${NODE_NAME}$i" "$cmd"
            done
        done

        echo "Write /etc/hosts file"
        cp hosts.template hosts
        for i in $(seq 1 $TOTAL_NODES); do
            echo ${PUB_NET}.22${i} ${NODE_NAME}${i} >> hosts
        done

        for i in $(seq 1 $TOTAL_NODES); do
            run_on_node "${NODE_NAME}$i" "sudo cp /vagrant/hosts /etc/hosts"
        done

        echo "Set up ssh between the nodes"
        copy_to_node "./insecure_private_key" "/home/vagrant/.ssh/id_rsa" "${NODE_NAME}1"
        ssh-keygen -y -f ./insecure_private_key > ./insecure_public_key
        
        for i in $(seq 1 $TOTAL_NODES); do
            copy_to_node "./insecure_public_key" "/home/vagrant/.ssh/id_rsa.pub" "${NODE_NAME}$i"
            run_on_node "${NODE_NAME}$i" 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys'
            run_on_node "${NODE_NAME}1" "echo uptime|ssh -o StrictHostKeyChecking=no ${PUB_NET}.22${i}"
        done

        echo "Script $(basename "$0") has finished"
        exit 0
    fi
fi

# Generate hosts.yaml content for both vagrant and physical
echo "Generate the hosts.yaml content"
generate_hosts_yaml() {
    local yaml="all:\n  hosts:"
    
    # Add hosts
    for i in $(seq 1 $TOTAL_NODES); do
        local host_ip
        if [[ "$LOCATION" == "vagrant" ]]; then
            host_ip="${PUB_NET}.22${i}"
        else
            host_ip=$(ping -c1 ${NODE_NAME}$i|head -1|cut -d\( -f2|cut -d\) -f1)
        fi
        yaml+="
    ${NODE_NAME}$i:
      ansible_host: ${host_ip}
      ip: ${host_ip}
      access_ip: ${host_ip}"
    done

    # Add control plane nodes
    yaml+="
  children:
    kube_control_plane:
      hosts:"
    for i in $(seq 1 $CONTROL_NODES); do
        yaml+="
        ${NODE_NAME}$i:"
    done

    # Add worker nodes
    yaml+="
    kube_node:
      hosts:"
    for i in $(seq $((CONTROL_NODES + 1)) $((TOTAL_NODES))); do
        yaml+="
        ${NODE_NAME}$i:"
    done

    # Add etcd nodes
    yaml+="
    etcd:
      hosts:"
    for i in $(seq 1 $CONTROL_NODES); do
        yaml+="
        ${NODE_NAME}$i:"
    done

    # Add remaining configuration
    yaml+='
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    kube_dns:
      vars:
        kube_dns_mode: "coredns"
        kube_dns_replicas: 2
    calico_rr:
      hosts: {}'

    echo -e "$yaml"
}

echo "$(generate_hosts_yaml)" > hosts.yaml
copy_to_node hosts.yaml hosts.yaml "${NODE_NAME}1"

# Clone kubespray repository
echo "Clone the kubespray repository"
CLONE_CMD='
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
    fi'

run_on_node "${NODE_NAME}1" "$CLONE_CMD"

# Common setup steps
INVENTORY_PATH="${LOCATION}_kubernetes"
echo "Set up the cluster"
run_on_node "${NODE_NAME}1" "
    cp -rfp /home/vagrant/kubespray/inventory/sample /home/vagrant/kubespray/inventory/${INVENTORY_PATH} &&
    cp ./hosts.yaml ./kubespray/inventory/${INVENTORY_PATH}/hosts.yaml &&
    sed -i -E \"/^kube_version:/s/.*/kube_version: '$KUBE_VERSION'/\" /home/vagrant/kubespray/inventory/${INVENTORY_PATH}/group_vars/k8s_cluster/k8s-cluster.yml &&
    sed -i -E \"/^kube_network_plugin:/s/.*/kube_network_plugin: '$KUBE_NETWORK_PLUGIN'/\" /home/vagrant/kubespray/inventory/${INVENTORY_PATH}/group_vars/k8s_cluster/k8s-cluster.yml"

# Configure nodes
echo "Disable firewalls, enable IPv4 forwarding, and switch off swap on all nodes"
NODE_SETUP_CMD='
    sudo systemctl stop firewalld &&
    sudo systemctl disable firewalld &&
    echo net.ipv4.ip_forward=1 | sudo tee -a /etc/sysctl.conf &&
    sudo sed -i "/ swap / s/^\(.*\)$/#\1/g" /etc/fstab &&
    sudo swapoff -a'

for i in $(seq 1 $TOTAL_NODES); do
    run_on_node "${NODE_NAME}$i" "$NODE_SETUP_CMD"
done

# Run Ansible playbook
echo "Run Ansible playbook to install Kubernetes"
run_on_node "${NODE_NAME}1" "
    sudo apt-get update && sudo apt-get install -y python3 python3-venv &&
    python3 -m venv /home/vagrant/.py3kubespray &&
    . ./.py3kubespray/bin/activate &&
    cd kubespray &&
    pip install -r requirements.txt &&
    ansible-playbook -i ./inventory/${INVENTORY_PATH}/hosts.yaml --become --become-user=root cluster.yml"

# Setup Kubernetes config
echo "Copy Kubernetes configuration to the user"
run_on_node "${NODE_NAME}1" '
    mkdir -p ./.kube &&
    sudo cp /etc/kubernetes/admin.conf ./.kube/config &&
    sudo chown $(id -u):$(id -g) ./.kube/config'

# Install additional components
echo "Install Helm on the primary node"
run_on_node "${NODE_NAME}1" 'sudo snap install helm --classic'

echo "Install Metrics Server"
run_on_node "${NODE_NAME}1" 'kubectl apply -f https://dev.ellisbs.co.uk/files/components.yaml'

if [ ! -z "$OPENAI_API_KEY" ]; then
    echo "Install k8sgpt"
    run_on_node "${NODE_NAME}1" "
        curl -Lo /tmp/k8sgpt.deb https://github.com/k8sgpt-ai/k8sgpt/releases/download/v0.3.24/k8sgpt_\$(uname -m | sed 's/x86_64/amd64/').deb &&
        sudo dpkg -i /tmp/k8sgpt.deb &&
        k8sgpt auth add --backend openai --model gpt-3.5-turbo --password $OPENAI_API_KEY"
fi

# Setup service monitor
echo "Setup service monitor service"
copy_to_node service-monitor.service service-monitor.service "${NODE_NAME}1"
copy_to_node service-monitor.sh service-monitor.sh "${NODE_NAME}1"
run_on_node "${NODE_NAME}1" '
    sudo mv service-monitor.service /etc/systemd/system/service-monitor.service &&
    sudo mv service-monitor.sh /bin/service-monitor.sh &&
    sudo chmod +x /bin/service-monitor.sh &&
    sudo systemctl daemon-reload &&
    sudo systemctl enable service-monitor.service
    sudo systemctl start service-monitor.service'

echo "Script $(basename "$0") has finished"
