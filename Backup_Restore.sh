#!/usr/bin/env bash

set -e
set -u

VELERO_VERSION="v1.12.0"
VELERO_CLI_PATH="/usr/local/bin/velero"
CREDENTIALS_FILE="velero-credentials"
VELERO_DEPLOYMENT="deployment/velero"
NAMESPACE="velero"
AWS_REGION="eu-west-2"
S3_URL="http://192.168.0.14:4566"
BUCKET_NAME="test"

# Check if Velero CLI is already installed
if ! command -v velero &>/dev/null || [[ "$(velero version --client-only)" != *"${VELERO_VERSION}"* ]]; then
    echo "Installing Velero..."
    wget -q "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    tar -xzf "velero-${VELERO_VERSION}-linux-amd64.tar.gz"
    sudo mv "velero-${VELERO_VERSION}-linux-amd64/velero" "$VELERO_CLI_PATH"
else
    echo "Velero is already installed. Skipping installation."
fi

# Check if credentials file exists
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "Creating mock AWS credentials for localstack..."
    cat <<EOF >"$CREDENTIALS_FILE"
[default]
aws_access_key_id = test
aws_secret_access_key = test
EOF
else
    echo "Credentials file already exists. Skipping creation."
fi

# Check if Velero is already installed in the cluster
if ! kubectl get ns "$NAMESPACE" &>/dev/null; then
    echo "Setting up Velero in the cluster..."
    velero install \
        --provider aws \
        --plugins velero/velero-plugin-for-aws:v1.7.0 \
        --bucket "$BUCKET_NAME" \
        --backup-location-config "region=${AWS_REGION},s3Url=${S3_URL},s3ForcePathStyle=true" \
        --secret-file "./${CREDENTIALS_FILE}" \
        --use-volume-snapshots=false
else
    echo "Velero is already installed in the cluster. Skipping installation."
fi

# Wait for Velero deployment to be ready
if ! kubectl get "$VELERO_DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
    echo "Waiting for Velero deployment to be ready..."
    kubectl wait --for=condition=available --timeout=300s "$VELERO_DEPLOYMENT" -n "$NAMESPACE"
else
    echo "Velero deployment is already available. Skipping wait."
fi

echo "Finding the latest completed backup..."
LATEST_BACKUP=""
BACKUP_TIMEOUT=300  # 5 minutes
BACKUP_INTERVAL=10  # Check every 10 seconds
backup_start_time=$(date +%s)

while [ -z "$LATEST_BACKUP" ]; do
    BACKUP_JSON=$(velero get backups -o json || echo "{}")

    # Handle both single backup object and list of backups
    if echo "$BACKUP_JSON" | jq -e '.kind == "Backup"' &>/dev/null; then
        # Single backup object
        if [ "$(echo "$BACKUP_JSON" | jq -r '.status.phase')" == "Completed" ]; then
            LATEST_BACKUP=$(echo "$BACKUP_JSON" | jq -r '.metadata.name')
        fi
    else
        # List of backups
        LATEST_BACKUP=$(echo "$BACKUP_JSON" | jq -r '.items[] | select(.status.phase == "Completed") | .metadata.name' | sort | tail -n 1)
    fi

    if [ -n "$LATEST_BACKUP" ]; then
        echo "Found latest completed backup: $LATEST_BACKUP"
        break
    else
        echo "No completed backups found. Waiting..."
    fi

    # Check if timeout has been reached
    current_time=$(date +%s)
    elapsed=$((current_time - backup_start_time))
    if [ $elapsed -ge $BACKUP_TIMEOUT ]; then
        echo "Timeout reached. No completed backup found."
        exit 1
    fi

    sleep $BACKUP_INTERVAL
done

# Check for existing restore
echo "Checking for existing restore from the latest backup..."
RESTORE_JSON=$(velero restore get -o json || echo "{}")
EXISTING_RESTORE=$(echo "$RESTORE_JSON" | jq -r --arg LATEST_BACKUP "$LATEST_BACKUP" '.items[]? | select(.spec.backupName == $LATEST_BACKUP) | .metadata.name')

if [ -n "$EXISTING_RESTORE" ]; then
    echo "A restore for backup $LATEST_BACKUP already exists: $EXISTING_RESTORE. Skipping restore initiation."
    echo "Restore $EXISTING_RESTORE already completed. Exiting."
    exit 0
else
    echo "Initiating a restore for backup: $LATEST_BACKUP"
    RESTORE_OUTPUT=$(velero restore create --from-backup "$LATEST_BACKUP" 2>&1)
    echo "Restore command output: $RESTORE_OUTPUT"

    if echo "$RESTORE_OUTPUT" | grep -q "Restore request .* submitted successfully"; then
        RESTORE_NAME=$(echo "$RESTORE_OUTPUT" | grep -oP 'Restore request "\K[^\"]+')
        echo "Restore initiated successfully: $RESTORE_NAME"
    else
        echo "Failed to initiate restore. Exiting."
        exit 1
    fi
fi

# Wait for the restore to complete
echo "Waiting for restore to complete..."
TIMEOUT=600  # 10 minutes timeout
INTERVAL=10  # Check every 10 seconds
start_time=$(date +%s)

while true; do
    RESTORE_STATUS=$(velero restore get "$RESTORE_NAME" --output json 2>/dev/null | jq -r '.status.phase')

    case "$RESTORE_STATUS" in
        "Completed")
            echo "Restore $RESTORE_NAME completed successfully."
            exit 0
            ;;
        "PartiallyFailed"|"Failed")
            echo "Restore $RESTORE_NAME failed with status: $RESTORE_STATUS"
            velero restore logs "$RESTORE_NAME"
            exit 1
            ;;
        "InProgress")
            echo "Restore $RESTORE_NAME is still in progress..."
            ;;
        *)
            echo "Unexpected restore status: $RESTORE_STATUS"
            ;;
    esac

    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -ge $TIMEOUT ]; then
        echo "Timeout reached. Restore $RESTORE_NAME is still in progress."
        exit 1
    fi

    sleep $INTERVAL
done
