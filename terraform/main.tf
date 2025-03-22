locals {
  vm_config = {
    pm1 = {
      target_node = "node1"
      template    = "ubuntu-2404-template"
      vmid_offset = 0
    }
    pm2 = {
      target_node = "node2"
      template    = "ubuntu-2404-template"
      vmid_offset = 100
    }
    pm3 = {
      target_node = "node3"
      template    = "ubuntu-2404-template"
      vmid_offset = 200
    }
    pm4 = {
      target_node = "node4"
      template    = "ubuntu-2404-template"
      vmid_offset = 300
    }
  }
}

# Create VMs on node1
resource "proxmox_vm_qemu" "vm_node1" {
  provider = proxmox.node1
  for_each = {
    for name, config in local.vm_config :
    name => config
    if config.target_node == "node1"
  }
  target_node     = each.value.target_node
  name            = each.key
  agent           = 1
  vmid            = 200 + each.value.vmid_offset
  clone           = each.value.template
  full_clone      = true
  clone_wait      = 120
  additional_wait = 60
  onboot          = true

  # Basic VM settings
  cores  = 2
  memory = 4096

  # Define the primary disk
  disk {
    slot    = "scsi0"
    size    = "32G"
    storage = "local-lvm"
    type    = "disk"
  }

  # Define the Cloud-Init drive
  disk {
    slot    = "ide2"
    storage = "local-lvm"
    type    = "cdrom"
  }

  network {
    id     = 0
    bridge = "vmbr0"
    model  = "virtio"
  }

  os_type = "cloud-init"

  # Set boot order
  boot     = "order=scsi0;ide2;net0"
  bootdisk = "scsi0"

  scsihw = "virtio-scsi-single"

  # Cloud-Init user data to install and start the guest agent
  cicustom = "user=local:snippets/${each.key}-cloudinit.cfg"

  lifecycle {
    ignore_changes = [
      network,
      disk,
      clone,
      qemu_os,
      desc,
      full_clone,
      scsihw
    ]
  }
}

# Create VMs on node2
resource "proxmox_vm_qemu" "vm_node2" {
  provider = proxmox.node2
  for_each = {
    for name, config in local.vm_config :
    name => config
    if config.target_node == "node2"
  }

  target_node     = each.value.target_node
  name            = each.key
  agent           = 1
  vmid            = 300 + each.value.vmid_offset
  clone           = each.value.template
  full_clone      = true
  clone_wait      = 120
  additional_wait = 60
  onboot          = true

  # Basic VM settings
  cores  = 2
  memory = 4096

  # Define the primary disk
  disk {
    slot    = "scsi0"
    size    = "32G"
    storage = "local-lvm"
    type    = "disk"
  }

  # Define the Cloud-Init drive
  disk {
    slot    = "ide2"
    storage = "local-lvm"
    type    = "cdrom"
  }

  network {
    id     = 0
    bridge = "vmbr0"
    model  = "virtio"
  }

  os_type = "cloud-init"

  # Set boot order
  boot     = "order=scsi0;ide2;net0"
  bootdisk = "scsi0"

  scsihw = "virtio-scsi-single"

  # Cloud-Init user data to install and start the guest agent
  cicustom = "user=local:snippets/${each.key}-cloudinit.cfg"

  lifecycle {
    ignore_changes = [
      network,
      disk,
      clone,
      qemu_os,
      desc,
      full_clone,
      scsihw
    ]
  }
}

# Create VMs on node3
resource "proxmox_vm_qemu" "vm_node3" {
  provider = proxmox.node3
  for_each = {
    for name, config in local.vm_config :
    name => config
    if config.target_node == "node3"
  }

  target_node     = each.value.target_node
  name            = each.key
  agent           = 1
  vmid            = 400 + each.value.vmid_offset
  clone           = each.value.template
  full_clone      = true
  clone_wait      = 120
  additional_wait = 60
  onboot          = true

  # Basic VM settings
  cores  = 2
  memory = 4096

  # Define the primary disk
  disk {
    slot    = "scsi0"
    size    = "32G"
    storage = "local-lvm"
    type    = "disk"
  }

  # Define the Cloud-Init drive
  disk {
    slot    = "ide2"
    storage = "local-lvm"
    type    = "cdrom"
  }

  network {
    id     = 0
    bridge = "vmbr0"
    model  = "virtio"
  }

  os_type = "cloud-init"

  # Set boot order
  boot     = "order=scsi0;ide2;net0"
  bootdisk = "scsi0"

  scsihw = "virtio-scsi-single"

  # Cloud-Init user data to install and start the guest agent
  cicustom = "user=local:snippets/${each.key}-cloudinit.cfg"

  lifecycle {
    ignore_changes = [
      network,
      disk,
      clone,
      qemu_os,
      desc,
      full_clone,
      scsihw
    ]
  }
}

# Create VMs on node4
resource "proxmox_vm_qemu" "vm_node4" {
  provider = proxmox.node4
  for_each = {
    for name, config in local.vm_config :
    name => config
    if config.target_node == "node4"
  }

  target_node     = each.value.target_node
  name            = each.key
  agent           = 1
  vmid            = 500 + each.value.vmid_offset
  clone           = each.value.template
  full_clone      = true
  clone_wait      = 120
  additional_wait = 60
  onboot          = true

  # Basic VM settings
  cores  = 2
  memory = 4096

  # Define the primary disk
  disk {
    slot    = "scsi0"
    size    = "32G"
    storage = "local-lvm"
    type    = "disk"
  }

  # Define the Cloud-Init drive
  disk {
    slot    = "ide2"
    storage = "local-lvm"
    type    = "cdrom"
  }

  network {
    id     = 0
    bridge = "vmbr0"
    model  = "virtio"
  }

  os_type = "cloud-init"

  # Set boot order
  boot     = "order=scsi0;ide2;net0"
  bootdisk = "scsi0"

  scsihw = "virtio-scsi-single"

  # Cloud-Init user data to install and start the guest agent
  cicustom = "user=local:snippets/${each.key}-cloudinit.cfg"

  lifecycle {
    ignore_changes = [
      network,
      disk,
      clone,
      qemu_os,
      desc,
      full_clone,
      scsihw
    ]
  }
}

# Provision Cloud-Init user data files
# Provision Cloud-Init user data files with hostname configuration
resource "local_file" "cloud_init_userdata" {
  for_each = local.vm_config

  filename = "${each.key}-cloudinit.cfg"
  content  = <<-EOF
    #cloud-config
    package_update: true
    packages:
      - qemu-guest-agent
    hostname: ${each.key}
    fqdn: ${each.key}.local
    write_files:
      - path: /etc/hostname
        content: ${each.key}
      - path: /etc/hosts
        content: |
          127.0.0.1 localhost
          127.0.1.1 ${each.key}.local ${each.key}
    runcmd:
      - systemctl enable --now qemu-guest-agent
      - hostnamectl set-hostname ${each.key}
  EOF
}
