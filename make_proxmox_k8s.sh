#!/usr/bin/env bash
set -e  # Exit on failure

sudo mkdir -p ~/.ssh
echo "$NODE1_KEY" | base64 --decode > ~/.ssh/id_node1
sudo chmod 600 ~/.ssh/id_node1

echo "$NODE1 node1" | sudo tee -a /etc/hosts
echo "$NODE2 node2" | sudo tee -a /etc/hosts
echo "$NODE3 node3" | sudo tee -a /etc/hosts
echo "$NODE4 node4" | sudo tee -a /etc/hosts

# Function to get IP
get_ip() {
    local NODE=$1
    local VMID=$2
    ssh -i ~/.ssh/id_node1 root@$NODE "qm guest exec $VMID -- ip -4 -j addr show" | \
        jq -r '.["out-data"] | fromjson | map(.addr_info[] | select(.family == "inet") | .local) | map(select(. != "127.0.0.1")) | last'
}

NODE1_IP=$(get_ip "node1" 200)
NODE2_IP=$(get_ip "node2" 400)
NODE3_IP=$(get_ip "node3" 600)
NODE4_IP=$(get_ip "node4" 800)

echo "$NODE1_IP pm1" >> /etc/hosts
echo "$NODE2_IP pm2" >> /etc/hosts
echo "$NODE3_IP pm3" >> /etc/hosts
echo "$NODE4_IP pm4" >> /etc/hosts

export OPENAI_API_KEY=$OPENAI_API_KEY

./Make_Kubernetes.sh --location physical SKIP_UP
