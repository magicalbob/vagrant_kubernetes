terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc9"
    }
  }
}

provider "proxmox" {
  # Alias for node to tell them apart
  alias = "node1"

  # URL for the Proxmox API
  pm_api_url = "https://node1:8006/api2/json"

  # API token ID and secret would be preferred, but since you have root credentials:
  pm_user     = "root@pam"
  pm_password = "jaK3th3p3g!"

  # Skip TLS verification if you're using self-signed certificates
  pm_tls_insecure = true
}

provider "proxmox" {
  # Alias for node to tell them apart
  alias = "node2"

  # URL for the Proxmox API
  pm_api_url = "https://node2:8006/api2/json"

  # API token ID and secret would be preferred, but since you have root credentials:
  pm_user     = "root@pam"
  pm_password = "jaK3th3p3g!"

  # Skip TLS verification if you're using self-signed certificates
  pm_tls_insecure = true
}

provider "proxmox" {
  # Alias for node to tell them apart
  alias = "node3"

  # URL for the Proxmox API
  pm_api_url = "https://node3:8006/api2/json"

  # API token ID and secret would be preferred, but since you have root credentials:
  pm_user     = "root@pam"
  pm_password = "jaK3th3p3g!"

  # Skip TLS verification if you're using self-signed certificates
  pm_tls_insecure = true
}

provider "proxmox" {
  # Alias for node to tell them apart
  alias = "node4"

  # URL for the Proxmox API
  pm_api_url = "https://node4:8006/api2/json"

  # API token ID and secret would be preferred, but since you have root credentials:
  pm_user     = "root@pam"
  pm_password = "jaK3th3p3g!"

  # Skip TLS verification if you're using self-signed certificates
  pm_tls_insecure = true
}


