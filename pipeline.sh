#!/usr/bin/env sh
sudo add-apt-repository ppa:rmescandon/yq
sudo apt-get update
sudo rm -rf /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/debconf/*.dat /var/cache/apt/archives/lock
sudo dpkg --configure -a
sudo apt-get install -f
sudo apt-get install -y python3-dev python3-pip iproute2 jq gettext virtualbox yq ruby-full
sudo mv vagrant /usr/bin/ 2>/dev/null
./Vagrant_Kubernetes_Setup.sh UP_ONLY
cat Vagrantfile
echo "Checking Ruby syntax..."
ruby -c Vagrantfile || { echo "Ruby syntax error."; exit 1; }
./Vagrant_Kubernetes_Setup.sh SKIP_UP
cat hosts.yaml | yq eval
which vagrant
vagrant --help
