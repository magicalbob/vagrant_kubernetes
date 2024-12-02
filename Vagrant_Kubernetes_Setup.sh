#!/usr/bin/env bash

# Get the post alert common function
curl -o alert_functions.sh https://gitlab.ellisbs.co.uk/-/snippets/1/raw
source alert_functions.sh

# Check for other command line arguments
if [[ "$1" == "SKIP_UP" ]]; then
  export SKIP_UP=1
else
  export SKIP_UP=0
fi

if [[ "$1" == "UP_ONLY" ]]; then
  export UP_ONLY=1
else
  export UP_ONLY=0
fi

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

echo Read configuration from config.json
CONTROL_NODES=$(jq -r '.control_nodes' config.json)
WORKER_NODES=$(jq -r '.worker_nodes' config.json)
export TOTAL_NODES=$((CONTROL_NODES + WORKER_NODES))
export RAM_SIZE=$(jq -r '.ram_size' config.json)
export CPU_COUNT=$(jq -r '.cpu_count' config.json)
export PUB_NET=$(jq -r '.pub_net' config.json)
export KUBE_VERSION=$(jq -r '.kube_version' config.json)
export KUBESPRAY_VERSION=$(jq -r '.kubespray_version' config.json)

echo Create Vagrantfile from template
envsubst < Vagrantfile.template > Vagrantfile

if [ "$SKIP_UP" -eq 1 ]
then
  echo Skipping upping and provisioning
else
  if [ "$UP_ONLY" -eq 1 ]
  then
    echo Bring up all the nodes without provisioning
    vagrant up --no-provision

    echo Loop to check if all nodes are created and then provision
    while vagrant status | grep -q "not created (virtualbox)"; do
      echo "Not all nodes are created yet. Retrying..."
      vagrant up --no-provision
    done

    echo "Script `basename $0` has finished"
    exit 0
  fi
fi

echo Generate the hosts.yaml content
HOSTS_YAML="all:
  hosts:"

for i in $(seq 1 $TOTAL_NODES); do
  HOSTS_YAML+="
    node$i:
      ansible_host: ${PUB_NET}.21$i
      ip: ${PUB_NET}.21$i
      access_ip: ${PUB_NET}.21$i"
done

HOSTS_YAML+="
  children:
    kube_control_plane:
      hosts:"

for i in $(seq 1 $CONTROL_NODES); do
  HOSTS_YAML+="
        node$i:"
done

HOSTS_YAML+="
    kube_node:
      hosts:"

for i in $(seq $((CONTROL_NODES + 1)) $((TOTAL_NODES))); do
  HOSTS_YAML+="
        node$i:"
done

HOSTS_YAML+="
    etcd:
      hosts:"
for i in $(seq 1 $CONTROL_NODES); do
  HOSTS_YAML+="
        node$i:"
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

echo Write the hosts.yaml content to the file
echo "$HOSTS_YAML" > hosts.yaml

echo Set up ssh between the nodes
vagrant upload ~/.vagrant.d/insecure_private_key /home/vagrant/.ssh/id_rsa node1

echo Now create the public key from it
ssh-keygen -y -f ~/.vagrant.d/insecure_private_key > ./insecure_public_key

echo Copy the public key to each node
for i in $(seq 1 $TOTAL_NODES); do
  vagrant upload ./insecure_public_key /home/vagrant/.ssh/id_rsa.pub node$i
done

echo Append the public key to the authorized_keys file on each node
for i in $(seq 1 $TOTAL_NODES); do
  vagrant ssh -c 'cat /home/vagrant/.ssh/id_rsa.pub >> /home/vagrant/.ssh/authorized_keys' node$i
done

echo Do an intial ssh to each node from node1 
for i in $(seq 1 $TOTAL_NODES); do
  vagrant ssh -c "echo uptime|ssh -o StrictHostKeyChecking=no ${PUB_NET}.21${i}" node1
done

echo Clone the project to do the actual kubernetes cluster setup
vagrant ssh -c 'rm -rf /home/vagrant/kubespray' node1
vagrant ssh -c 'git clone https://github.com/kubernetes-sigs/kubespray.git /home/vagrant/kubespray || !!' node1
if [ ! -z "$KUBESPRAY_VERSION" ] && [ "$KUBESPRAY_VERSION" != "null" ]
then
  echo Checkout tag $KUBESPRAY_VERSION
  vagrant ssh -c "cd /home/vagrant/kubespray && git checkout $KUBESPRAY_VERSION" node1
fi

echo "Python requirements (and ruby)"
vagrant ssh -c 'sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y install python3.10-venv ruby' node1
vagrant ssh -c 'python3 -m venv /home/vagrant/.py3kubespray'  node1
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && pip install -r /home/vagrant/kubespray/requirements.txt'  node1

echo Write /etc/hosts file
echo Do an intial ssh to each node from node1
cp hosts.template hosts
for i in $(seq 1 $TOTAL_NODES); do
  echo ${PUB_NET}.21${i} node${i} >> hosts
done
echo Copy hosts file to each node
for i in $(seq 1 $TOTAL_NODES); do
  vagrant ssh -c "sudo cp /vagrant/hosts /etc/hosts" node${i}
done

echo Set up the cluster
vagrant ssh -c 'cp -rfp /home/vagrant/kubespray/inventory/sample /home/vagrant/kubespray/inventory/vagrant_kubernetes' node1
vagrant ssh -c "sed -i -E \"/^kube_version:/s/.*/kube_version: $KUBE_VERSION/\"  /home/vagrant/kubespray/inventory/vagrant_kubernetes/group_vars/k8s_cluster/k8s-cluster.yml" node1
vagrant ssh -c 'cp /vagrant/hosts.yaml /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml' node1
envsubst < build_inventory.template | sed 's/PUBLIC_NET.i/$PUBLIC_NET.$i/' > build_inventory.sh
chmod +x build_inventory.sh
echo Execute build_inventory.sh
vagrant ssh -c 'bash -c /vagrant/build_inventory.sh' node1

vagrant ssh -c 'cp /vagrant/addons.yml /home/vagrant/kubespray/inventory/vagrant_kubernetes/group_vars/k8s_cluster/addons.yml' node1||post_alert "addons yaml copy failed" "Critical" "k8s" "script" "copy of addons.yml failed" "copy of addons.yml to node1 failed"

echo Uncomment upstream dns servers in all.yaml
vagrant ssh -c 'sed -i "/upstream_dns_servers:/s/^# *//" ~/kubespray/inventory/vagrant_kubernetes/group_vars/all/all.yml' node1||post_alert "uncomment of upstream servers failed" "Critical" "k8s" "script" "uncomment of upstream servers failed" "uncomment of upstream servers in all.yaml failed"
vagrant ssh -c 'sed -i "/- 8.8.8.8/s/^# *//" ~/kubespray/inventory/vagrant_kubernetes/group_vars/all/all.yml' node1||post_alert "adding primary google dns failed" "Critical" "k8s" "script" "primary google dns add failed" "unable to add primary dns server"
vagrant ssh -c 'sed -i "/- 8.8.4.4/s/^# *//" ~/kubespray/inventory/vagrant_kubernetes/group_vars/all/all.yml' node1||post_alert "adding secondary google dns failed" "Critical" "k8s" "script" "secondary google dns add failed" "unable to add secondary dns server"

echo Disable firewalls, enable IPv4 forwarding and switch off swap
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && ansible all -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml -m shell -a "sudo systemctl stop firewalld && sudo systemctl disable firewalld"' node1
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && ansible all -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml -m shell -a "echo net.ipv4.ip_forward=1 | sudo tee -a /etc/sysctl.conf"' node1||post_alert "ip forward off failed" "Critical" "k8s" "script" "ip forward off failed" "no ip forward failed"
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && ansible all -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml -m shell -a "sudo sed -i \"/ swap / s/^\(.*\)$/#\1/g\" /etc/fstab && sudo swapoff -a"' node1||post_alert "swapoff failed" "Critical" "k8s" "script" "switch off of swap failed" "swap off failed"

echo Do install of kubernetes
vagrant ssh -c '. /home/vagrant/.py3kubespray/bin/activate && cd /home/vagrant/kubespray && ansible-playbook -i /home/vagrant/kubespray/inventory/vagrant_kubernetes/hosts.yaml --become --become-user=root /home/vagrant/kubespray/cluster.yml' node1||post_alert "install of kubernetes failed" "Critical" "k8s" "script" "kubernetes install failed" "kubernetes install failed"

echo Now copy /root/.kube/config to vagrant user
vagrant ssh -c 'mkdir -p /home/vagrant/.kube' node1||post_alert "mkdir for kube config failed" "Critical" "k8s" "script" "mkdir failed" "mkdir of dir for kube config failed"
vagrant ssh -c 'sudo cp /root/.kube/config /home/vagrant/.kube/config' node1||post_alert "copy kube config failed" "Critical" "k8s" "script" "copy failed" "copy of kube config failed"
vagrant ssh -c 'sudo chown vagrant:vagrant /home/vagrant/.kube/config' node1||post_alert "chown kube config failed" "Critical" "k8s" "script" "chown failed" "chown of kube config failed"

echo Install helm
vagrant ssh -c 'sudo snap install helm --classic' node1||post_alert "install helm failed" "High" "k8s" "script" "helm install failed" "install of helm failed"

echo Install Metrics Server
vagrant ssh -c 'kubectl apply -f https://dev.ellisbs.co.uk/files/components.yaml' node1||post_alert "install metrics server failed" "High" "k8s" "script" "metrics server install failed" "install of metrics server from ellisbs failed"

if [ ! -z "$OPENAI_API_KEY" ]
then
  echo Install k8sgpt
  vagrant ssh -c "curl -Lo /tmp/k8sgpt.deb https://github.com/k8sgpt-ai/k8sgpt/releases/download/v0.3.24/k8sgpt_$(uname -m|sed 's/x86_64/amd64/').deb" node1||post_alert "Cannot download k8sgpt" "High" "k8s" "script" "k8sgpt download failed" "download of k8s debian package failed"
  vagrant ssh -c 'sudo dpkg -i /tmp/k8sgpt.deb' node1||post_alert "Cannot install k8sgpt" "High" "k8s" "script" "k8sgpt failed to install" "dpkg install of k8sgpt.deb failed"
  vagrant ssh -c "k8sgpt auth add --backend openai --model gpt-3.5-turbo --password $OPENAI_API_KEY" node1||post_alert "Cannot install k8sgpt" "High" "k8s" "script" "k8sgpt failed to install" "'k8sgpt auth add --backend openai --model gpt-3.5-turbo --password $OPENAI_API_KEY node1' failed"
fi

echo "Script `basename $0` has finished"
