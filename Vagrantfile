# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # Common configuration for all VMs
  config.vm.box = "bento/ubuntu-22.04"
  config.vm.box_url = "bento/ubuntu-22.04"
  config.vm.provider "virtualbox" do |vb|
    vb.gui = false
    vb.memory = "8096"
    vb.cpus = 4
  end

  # Create 6 VMs with a private network and sequential IP addresses
  (1..6).each do |i|
    config.vm.define "node#{i}" do |node|
      node.vm.network "private_network", ip: "192.168.200.20#{i}"

      # Provision the VM with shell script
      node.vm.provision "shell", inline: <<-SHELL
        sudo apt-get update
        sudo apt-get upgrade -y
	sudo apt-get install -y net-tools
      SHELL
    end
  end

  # Create a public network shared among all VMs using bridged network (enp0s25)
  config.vm.network "public_network", bridge: "enp0s25"
end
