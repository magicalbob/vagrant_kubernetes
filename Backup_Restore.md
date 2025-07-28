Velero Backup and Restore Script (`Backup_Restore.sh`)
------------------------------------------------------

This Bash script automates the installation, configuration, and restore operations of **Velero** for backing up and restoring Kubernetes cluster resources and persistent volumes, using an S3-compatible object storage backend (e.g., Localstack).

### Main functions of the script:

1.  **Ensure Velero CLI is installed (specific version)**

    -   Checks if the Velero CLI exists and matches the expected version (`v1.12.0`).

    -   If missing or mismatched, downloads and installs the Velero CLI binary.

2.  **Create AWS credentials file for Velero**

    -   Generates a mock AWS credentials file (`velero-credentials`) with static access keys (`test`) for use with Localstack (a local S3-compatible service).

    -   Skips if the file already exists.

3.  **Install Velero in the Kubernetes cluster**

    -   Checks if the `velero` namespace exists; if not, installs Velero with the AWS provider and the AWS plugin.

    -   Configures Velero to use the specified S3 URL (`http://192.168.0.3:4566`), bucket (`test`), region (`eu-west-2`), and the credentials file.

    -   Disables volume snapshots, relying on backup of persistent volumes.

4.  **Wait for Velero deployment to become ready**

    -   If the Velero deployment is not found, waits up to 5 minutes for it to become available.

5.  **Create a PersistentVolume for SonarQube data**

    -   Defines a local PersistentVolume named `postgresql-data` on node `pm2` with 10Gi capacity, using the local storage path `/home/vagrant/projects/k8s_postgres/postgresql-data`.

    -   Applies node affinity so it can only be mounted on `pm2`.

    -   Creates the directory on `pm2` over SSH to prepare the storage path.

6.  **Locate the latest completed Velero backup**

    -   Queries Velero backups in JSON format and searches for the most recent backup with status `Completed`.

    -   Waits and retries for up to 5 minutes if no completed backup is found.

7.  **Check if a restore from the latest backup already exists**

    -   Queries existing Velero restores to avoid duplicate restore attempts.

8.  **Initiate a Velero restore if none exists for the latest backup**

    -   Starts a restore job using Velero from the latest backup.

    -   Extracts the restore name from Velero's output.

9.  **Wait for the restore operation to complete**

    -   Polls Velero restore status every 10 seconds, waiting up to 10 minutes.

    -   Reports success, failure, or timeout with appropriate messages.

    -   If the restore fails or partially fails, outputs restore logs for troubleshooting.

* * * * *

### Summary

This script streamlines managing Velero in your cluster by automating:

-   Installation of Velero CLI and Velero itself (configured for a local S3 backend).

-   Setup of a local PersistentVolume to match expected cluster state.

-   Backup discovery and conditional restore triggering.

-   Monitoring the restore process with timeout and error reporting.

It is designed to work with **Localstack** as a local AWS S3 mock and assumes a Velero-compatible Kubernetes environment.
