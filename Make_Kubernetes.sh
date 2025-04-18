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

copy_from_node() {
    local src="$1"
    local dest="$2"
    local node="$3"
    if [[ "$LOCATION" == "vagrant" ]]; then
        vagrant ssh "$node" -c "cp -v '$src' '/vagrant/$dest'"
    else
        scp -o StrictHostKeyChecking=no "${node}:$src" "${dest}"
    fi
}

# Retry function for commands
retry_command() {
    local max_attempts=$1
    local delay=$2
    local command=$3
    local node=$4
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "Executing command: $command (attempt $attempt of $max_attempts)"
        if run_on_node "$node" "$command"; then
            echo "Command succeeded on attempt $attempt"
            return 0
        else
            echo "Command failed on attempt $attempt"
            if [ $attempt -lt $max_attempts ]; then
                echo "Retrying in $delay seconds..."
                sleep $delay
            fi
            attempt=$((attempt+1))
        fi
    done
    
    echo "Command failed after $max_attempts attempts"
    return 1
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
START_RANGE=$(jq -r '.start_range' config.json)
KUBE_VERSION=$(jq -r '.kube_version' config.json)
KUBESPRAY_VERSION=$(jq -r '.kubespray_version' config.json)
NODE_NAME=$(jq -r '.node_name' config.json)
KUBE_NETWORK_PLUGIN=$(jq -r '.kube_network_plugin // "calico"' config.json)
BOX_NAME=$(jq -r '.box_name // "bento/ubuntu-22.04"' config.json)
DISK_SIZE=$(jq -r '.disk_size // "51200"' config.json)
MAC_ADDRESS=$(jq -r '.mac_address // "08:00:aa:aa:aa:aa" | gsub(":"; "")' config.json)

# Export variables
export CONTROL_NODES WORKER_NODES TOTAL_NODES RAM_SIZE CPU_COUNT PUB_NET START_RANGE KUBE_VERSION KUBESPRAY_VERSION NODE_NAME KUBE_NETWORK_PLUGIN BOX_NAME DISK_SIZE MAC_ADDRESS

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
        for i in $(seq 1 $TOTAL_NODES); do
          node="${NODE_NAME}${i}"
          echo "Bringing up node ${node}"
          
          # Attempt to bring up the node (with retry logic)
          max_attempts=3
          for attempt in $(seq 1 $max_attempts); do
            echo "Attempt $attempt of $max_attempts to bring up ${node}"
            
            # Run vagrant up and capture its exit status
            vagrant up --no-provision ${node}
            up_status=$?
            
            if [ $up_status -eq 0 ]; then
              # Even if command succeeded, verify the VM is actually running
              status=$(vagrant status ${node} --machine-readable | grep ",state," | cut -d, -f4)
              
              if [ "$status" = "running" ]; then
                # Double-check with SSH connectivity test
                if vagrant ssh ${node} -c "echo 'SSH connection successful'" >/dev/null 2>&1; then
                  echo "✅ Node ${node} is up and running with verified SSH access"
                  break
                else
                  echo "⚠️ Node ${node} appears to be running but SSH connection failed"
                fi
              else
                echo "⚠️ Node ${node} failed to start properly. Status: ${status}"
              fi
            else
              echo "⚠️ Vagrant up command failed with exit code: ${up_status}"
            fi
            
            # If we reach here, there was an issue. Try again if not last attempt
            if [ $attempt -lt $max_attempts ]; then
              echo "Waiting 30 seconds before retrying..."
              sleep 30
              
              # Try to halt the VM if it's in a bad state
              vagrant halt ${node} --force >/dev/null 2>&1 || true
            else
              echo "❌ ERROR: Failed to bring up node ${node} after $max_attempts attempts"
              exit 1
            fi
          done
        done

        echo "Set up ssh between the nodes"
        ssh-keygen -y -f ./insecure_private_key > ./insecure_public_key

        # Initial SSH setup on node1
        copy_to_node "./insecure_private_key" "/home/vagrant/.ssh/id_rsa" "${NODE_NAME}1"
        copy_to_node "./insecure_public_key" "/home/vagrant/.ssh/id_rsa.pub" "${NODE_NAME}1"
        run_on_node "${NODE_NAME}1" 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys'

        # Create and write hosts file
        echo "Create /etc/hosts file"
        cp hosts.template hosts
        for i in $(seq 1 $TOTAL_NODES); do
            echo ${PUB_NET}.${START_RANGE}${i} ${NODE_NAME}${i} >> hosts
        done

        # First ensure node1 can ping all other nodes
        echo "Verify all nodes are pingable from node1"
        for i in $(seq 2 $TOTAL_NODES); do
            echo "Checking if ${NODE_NAME}$i is reachable from node1..."
            PING_ATTEMPTS=0
            MAX_PING_ATTEMPTS=30
            PING_SUCCESS=0
            
            while [ $PING_ATTEMPTS -lt $MAX_PING_ATTEMPTS ] && [ $PING_SUCCESS -eq 0 ]; do
                PING_ATTEMPTS=$((PING_ATTEMPTS+1))
                if run_on_node "${NODE_NAME}1" "ping -c 1 ${PUB_NET}.${START_RANGE}${i}" > /dev/null 2>&1; then
                    echo "${NODE_NAME}$i is reachable from node1"
                    PING_SUCCESS=1
                else
                    echo "Waiting for ${NODE_NAME}$i to become reachable... (attempt $PING_ATTEMPTS/$MAX_PING_ATTEMPTS)"
                    sleep 5
                    
                    # If we've tried 15 times, try to help the VM
                    if [ $PING_ATTEMPTS -eq 15 ]; then
                        echo "Attempting to reconfigure network on ${NODE_NAME}$i..."
                        vagrant ssh -c "sudo dhclient -v" "${NODE_NAME}$i" || true
                    fi
                fi
            done
            
            if [ $PING_SUCCESS -eq 0 ]; then
                echo "Could not reach ${NODE_NAME}$i after $MAX_PING_ATTEMPTS attempts. Rebuilding VM..."
                vagrant reload "${NODE_NAME}$i --no-provision"
                
                # Check again after rebuild
                if ! run_on_node "${NODE_NAME}1" "ping -c 1 ${PUB_NET}.${START_RANGE}${i}" > /dev/null 2>&1; then
                    echo "ERROR: Still cannot reach ${NODE_NAME}$i after rebuilding. Please check network configuration."
                    exit 1
                fi
            fi
        done

        # Copy hosts file to all nodes and apply basic configuration
        for i in $(seq 1 $TOTAL_NODES); do
            echo "Configuring basic network for ${NODE_NAME}$i"
            # Try to copy hosts file multiple times in case of network issues
            MAX_ATTEMPTS=3
            for attempt in $(seq 1 $MAX_ATTEMPTS); do
                if run_on_node "${NODE_NAME}$i" "sudo cp /vagrant/hosts /etc/hosts"; then
                    echo "Successfully copied hosts file to ${NODE_NAME}$i"
                    break
                else
                    echo "Failed to copy hosts file to ${NODE_NAME}$i (attempt $attempt of $MAX_ATTEMPTS)"
                    [ $attempt -eq $MAX_ATTEMPTS ] && echo "WARNING: Could not copy hosts file to ${NODE_NAME}$i"
                    sleep 5
                fi
            done
        done

        # Now set up SSH keys on all nodes
        for i in $(seq 1 $TOTAL_NODES); do
            echo "Setting up SSH for ${NODE_NAME}$i"
            copy_to_node "./insecure_private_key" "/home/vagrant/.ssh/id_rsa" "${NODE_NAME}$i"
            copy_to_node "./insecure_public_key" "/home/vagrant/.ssh/id_rsa.pub" "${NODE_NAME}$i"
            run_on_node "${NODE_NAME}$i" 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys'
            # Try to connect from node1 to each node to establish SSH trust
            run_on_node "${NODE_NAME}1" "ssh -o StrictHostKeyChecking=no ${NODE_NAME}$i 'echo SSH test from node1 to ${NODE_NAME}$i successful'"
        done

        echo "Verifying SSH connectivity between all nodes"
        # Check if all nodes can connect to each other
        MAX_RETRY=3
        for attempt in $(seq 1 $MAX_RETRY); do
            all_nodes_healthy=true

            for i in $(seq 1 $TOTAL_NODES); do
                for j in $(seq 1 $TOTAL_NODES); do
                    echo "Testing SSH from ${NODE_NAME}$i to ${NODE_NAME}$j (attempt $attempt of $MAX_RETRY)..."
                    if ! run_on_node "${NODE_NAME}$i" "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${NODE_NAME}$j exit 2>/dev/null"; then
                        echo "WARNING: SSH from ${NODE_NAME}$i to ${NODE_NAME}$j failed"
                        all_nodes_healthy=false

                        # If this is the last attempt, try to remediate
                        if [ $attempt -eq $MAX_RETRY ]; then
                            echo "Attempting to remediate node ${NODE_NAME}$j..."

                            # First try restarting SSH on the problematic node
                            run_on_node "${NODE_NAME}$j" "sudo systemctl restart sshd" || true

                            # Wait a moment for SSH to restart
                            sleep 10

                            # Test again
                            if ! run_on_node "${NODE_NAME}$i" "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${NODE_NAME}$j exit 2>/dev/null"; then
                                echo "Remediation failed. Rebuilding node ${NODE_NAME}$j..."
                                vagrant reload "${NODE_NAME}$j --no-provision"

                                echo "Waiting 30 seconds for VM to fully initialize..."
                                sleep 30

                                # Copy hosts file and set up SSH for the rebuilt node
                                run_on_node "${NODE_NAME}$j" "sudo cp /vagrant/hosts /etc/hosts"
                                copy_to_node "./insecure_private_key" "/home/vagrant/.ssh/id_rsa" "${NODE_NAME}$j"
                                copy_to_node "./insecure_public_key" "/home/vagrant/.ssh/id_rsa.pub" "${NODE_NAME}$j"
                                run_on_node "${NODE_NAME}$j" 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys'

                                # Final verification
                                echo "Final verification of SSH connectivity to rebuilt node..."
                                if ! run_on_node "${NODE_NAME}$i" "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${NODE_NAME}$j exit 2>/dev/null"; then
                                    echo "ERROR: Failed to establish SSH connectivity to ${NODE_NAME}$j after rebuilding. Exiting."
                                    exit 1
                                fi
                            fi
                        fi
                    fi
                done
            done

            if $all_nodes_healthy; then
                echo "All nodes can connect to each other via SSH."
                break
            fi

            if [ $attempt -lt $MAX_RETRY ]; then
                echo "Retrying SSH connectivity check in 10 seconds..."
                sleep 10
            fi
        done

        echo "Update and upgrade each node"
        for i in $(seq 1 $TOTAL_NODES); do
            echo "Provisioning ${NODE_NAME}$i"
            export i
            envsubst < 01-netcfg.yaml.template > 01-netcfg.yaml
            
            # Apply core configuration in smaller batches with retries
            echo "Resizing disks and partitions on ${NODE_NAME}$i"
            retry_command 3 5 'sudo sgdisk -e /dev/sda' "${NODE_NAME}$i"
            retry_command 3 5 'sudo parted -s /dev/sda resizepart 3 100%' "${NODE_NAME}$i"
            retry_command 3 5 'sudo pvresize /dev/sda3' "${NODE_NAME}$i"
            retry_command 3 5 'sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv' "${NODE_NAME}$i"
            retry_command 3 5 'sudo resize2fs /dev/ubuntu-vg/ubuntu-lv' "${NODE_NAME}$i"
            
            echo "Configuring network on ${NODE_NAME}$i"
            retry_command 3 5 'sudo rm -rf /etc/netplan/*' "${NODE_NAME}$i"
            copy_to_node "01-netcfg.yaml" "01-netcfg.yaml" "${NODE_NAME}$i"
            retry_command 3 5 'sudo cp -v 01-netcfg.yaml /etc/netplan/01-netcfg.yaml' "${NODE_NAME}$i"
            retry_command 3 5 'sudo chmod 600 /etc/netplan/01-netcfg.yaml' "${NODE_NAME}$i"
            retry_command 3 5 'sudo chown root:root /etc/netplan/01-netcfg.yaml' "${NODE_NAME}$i"
            retry_command 3 5 'sudo netplan generate' "${NODE_NAME}$i"
            retry_command 3 5 'sudo netplan apply' "${NODE_NAME}$i"

            echo "Configuring chrony on ${NODE_NAME}$i"
            copy_to_node "chrony.conf" "chrony.conf" "${NODE_NAME}$i"
            retry_command 3 5 'sudo cp -v chrony.conf /etc/chrony/chrony.conf' "${NODE_NAME}$i"
            
            echo "Installing packages on ${NODE_NAME}$i"
            retry_command 3 5 'echo "grub-pc grub-pc/install_devices multiselect /dev/sda" | sudo debconf-set-selections' "${NODE_NAME}$i"
            retry_command 3 5 'DEBIAN_FRONTEND=noninteractive sudo apt-get update' "${NODE_NAME}$i"
            retry_command 3 5 'DEBIAN_FRONTEND=noninteractive sudo apt-get upgrade -y' "${NODE_NAME}$i"
            retry_command 3 5 'sudo apt-get install -y net-tools ruby jq chrony' "${NODE_NAME}$i"
            retry_command 3 5 'sudo systemctl enable chrony --now' "${NODE_NAME}$i"
            retry_command 3 5 'sudo chronyc -a makestep' "${NODE_NAME}$i"
            
            echo "Configuring DNS on ${NODE_NAME}$i"
            retry_command 3 5 'sudo systemctl stop systemd-resolved' "${NODE_NAME}$i"
            retry_command 3 5 'sudo systemctl disable systemd-resolved' "${NODE_NAME}$i"
            retry_command 3 5 'sudo unlink /etc/resolv.conf' "${NODE_NAME}$i"
            copy_to_node "resolv.conf" "resolv.conf" "${NODE_NAME}$i"
            retry_command 3 5 'sudo cp -v resolv.conf /etc/resolv.conf' "${NODE_NAME}$i"
        done

        for i in $(seq 1 $TOTAL_NODES); do
            echo "Disable IPv6 ${NODE_NAME}$i"
            retry_command 3 5 "
                sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1;
                sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1;
                sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1;
                echo 'net.ipv6.conf.all.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf;
                echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf;
                echo 'net.ipv6.conf.lo.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf;
            " "${NODE_NAME}$i"
        done

        # Final check of SSH connectivity
        echo "Final verification of SSH connectivity between all nodes"
        for i in $(seq 1 $TOTAL_NODES); do
            for j in $(seq 1 $TOTAL_NODES); do
                echo "Testing SSH from ${NODE_NAME}$i to ${NODE_NAME}$j..."
                if ! run_on_node "${NODE_NAME}$i" "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${NODE_NAME}$j 'echo SUCCESS' 2>/dev/null"; then
                    echo "ERROR: SSH from ${NODE_NAME}$i to ${NODE_NAME}$j still failing after all remediation attempts."
                    echo "Please check the network configuration manually."
                    exit 1
                fi
                echo "SSH from ${NODE_NAME}$i to ${NODE_NAME}$j successful."
            done
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
            host_ip="${PUB_NET}.${START_RANGE}${i}"
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
CLONE_CMD=$(cat <<EOF
export KUBESPRAY_VERSION=$KUBESPRAY_VERSION
MAX_ATTEMPTS=3
ATTEMPT=1
while [ \$ATTEMPT -le \$MAX_ATTEMPTS ]; do
    echo "Attempt \$ATTEMPT of \$MAX_ATTEMPTS"
    if [ ! -d "./kubespray" ] || [ -z "\$(ls -A ./kubespray)" ]; then
        git clone https://github.com/kubernetes-sigs/kubespray.git /home/vagrant/kubespray && break
    else
        echo "Directory exists and is not empty. Removing contents..."
        rm -rf ./kubespray
    fi
    ATTEMPT=\$((ATTEMPT+1))
    [ \$ATTEMPT -le \$MAX_ATTEMPTS ] && echo "Retrying in 5 seconds..." && sleep 5
done

if [ \$ATTEMPT -gt \$MAX_ATTEMPTS ]; then
    echo "Failed to clone repository after \$MAX_ATTEMPTS attempts"
    exit 1
fi

if [ ! -z "\$KUBESPRAY_VERSION" ] && [ "\$KUBESPRAY_VERSION" != "null" ]; then
    echo "Checkout tag \$KUBESPRAY_VERSION"
    cd ./kubespray && git checkout \$KUBESPRAY_VERSION
fi
EOF
)

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

# Set up ansible config
copy_to_node ansible.cfg ansible.cfg "${NODE_NAME}1"

# Copy cluster.yml from node1
copy_from_node kubespray/playbooks/cluster.yml cluster.yml "${NODE_NAME}1"

# Modify cluster.yml using awk
awk '
NR==1 && /^---/ {
    print "---"
    print "- hosts: all"
    print "  gather_facts: yes"
    print "  tasks:"
    print "    - name: Ensure /etc/resolv.conf exists with proper nameservers"
    print "      copy:"
    print "        content: |"
    print "          nameserver 8.8.8.8"
    print "          nameserver 1.1.1.1"
    print "          options timeout:2 attempts:3 rotate"
    print "          search Home"
    print "        dest: /etc/resolv.conf"
    print "        force: yes"
    print "        mode: \"0644\""
    print "      become: yes"
    print ""
    print "    - name: Create stat fact for resolv.conf"
    print "      stat:"
    print "        path: /etc/resolv.conf"
    print "      register: resolvconf_stat"
    print ""
    print "    - name: Slurp resolv.conf content"
    print "      slurp:"
    print "        src: /etc/resolv.conf"
    print "      register: resolvconf_slurp"
    print "      when: resolvconf_stat.stat.exists"
    print "      "
    print "    - name: Debug resolvconf variables"
    print "      debug:"
    print "        msg: "
    print "          - \"stat exists: {{ resolvconf_stat.stat.exists }}\""
    print "          - \"slurp defined: {{ resolvconf_slurp is defined }}\""
    print ""
}

!/^---/ {print}
' cluster.yml > cluster.yml.new

# Copy modified cluster.yml back to node1
copy_to_node cluster.yml.new kubespray/playbooks/cluster.yml "${NODE_NAME}1"

# Run Ansible playbook
echo "Run Ansible playbook to install Kubernetes"
run_on_node "${NODE_NAME}1" "
    sudo apt-get update && sudo apt-get install -y python3 python3-venv &&
    python3 -m venv /home/vagrant/.py3kubespray &&
    . ./.py3kubespray/bin/activate &&
    cd kubespray &&
    mkdir -p ./inventory/${INVENTORY_PATH}/group_vars/all &&
    echo 'resolvconf_mode: none' > ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo 'dns_mode: none' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo 'enable_resolv_conf_update: false' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo 'networkmanager_enabled:' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo '  rc: 1' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    # Add kube-apiserver configurations
    echo 'kube_kubeadm_apiserver_extra_args:' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo '  request-timeout: "3m0s"' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo 'kube_apiserver_resources:' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo '  requests:' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo '    cpu: 500m' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo '    memory: 1Gi' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    # Add etcd configurations
    echo 'etcd_quota_backend_bytes: 8589934592' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo 'etcd_max_request_bytes: 33554432' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo 'etcd_compaction_batch_limit: 1000' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml &&
    echo 'etcd_max_txn_ops: 10000' >> ./inventory/${INVENTORY_PATH}/group_vars/all/all.yml
    pip install -r requirements.txt &&
    pip install ara &&
    ansible-playbook -i ./inventory/${INVENTORY_PATH}/hosts.yaml --become --become-user=root cluster.yml --skip-tags resolvconf"

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
