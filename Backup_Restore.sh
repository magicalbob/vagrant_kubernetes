#!/usr/bin/env bash

set -e

echo "Install velero"
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xvf velero-v1.12.0-linux-amd64.tar.gz
sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/

echo "Set up mock aws creds for localstack"
cat << EOF > velero-credentials
[default]
aws_access_key_id = test
aws_secret_access_key = test
EOF

echo "Setup backup to aws (localstack) by velero"
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.7.0 \
  --bucket test \
  --backup-location-config region=eu-west-2,s3Url=http://192.168.0.14:4566,s3ForcePathStyle=true \
  --secret-file ./velero-credentials \
  --use-volume-snapshots=false

echo "Wait for velero deployment to be ready"
kubectl wait --for=condition=available --timeout=300s deployment/velero -n velero

echo "Get name of latest completed backup"
LATEST_BACKUP=""
BACKUP_TIMEOUT=300  # 5 minutes timeout for finding a backup
BACKUP_INTERVAL=10  # Check every 10 seconds

backup_start_time=$(date +%s)

while [ -z "$LATEST_BACKUP" ]; do
    BACKUP_JSON=$(velero get backups -o json)
    if [ -z "$BACKUP_JSON" ]; then
        echo "No backups found. Waiting..."
    else
        LATEST_BACKUP=$(echo "$BACKUP_JSON" | jq -r 'select(.status.phase == "Completed") | .metadata.name')
        if [ -n "$LATEST_BACKUP" ]; then
            echo "Found latest completed backup: $LATEST_BACKUP"
            break
        else
            echo "No completed backups found. Waiting..."
        fi
    fi

    current_time=$(date +%s)
    elapsed=$((current_time - backup_start_time))

    if [ $elapsed -ge $BACKUP_TIMEOUT ]; then
        echo "Timeout reached. No completed backup found."
        exit 1
    fi

    sleep $BACKUP_INTERVAL
done

echo "Attempting to create restore"
RESTORE_OUTPUT=$(velero restore create --from-backup ${LATEST_BACKUP} 2>&1)
echo "Restore command output:"
echo "$RESTORE_OUTPUT"

if echo "$RESTORE_OUTPUT" | grep -q "Restore request .* submitted successfully"; then
    echo "Restore initiated successfully"
    RESTORE_NAME=$(echo "$RESTORE_OUTPUT" | grep -oP 'Restore request "\K[^"]+')
else
    echo "Failed to initiate restore. Error output:"
    echo "$RESTORE_OUTPUT"
    exit 1
fi

echo "Waiting for restore to complete..."
TIMEOUT=600  # 10 minutes timeout
INTERVAL=10  # Check every 10 seconds

start_time=$(date +%s)

while true; do
    RESTORE_STATUS=$(velero restore get "$RESTORE_NAME" --output json 2>/dev/null | jq -r '.status.phase')
    
    if [ "$RESTORE_STATUS" == "Completed" ]; then
        echo "Restore $RESTORE_NAME completed successfully."
        exit 0
    elif [ "$RESTORE_STATUS" == "PartiallyFailed" ] || [ "$RESTORE_STATUS" == "Failed" ]; then
        echo "Restore $RESTORE_NAME failed with status: $RESTORE_STATUS"
        velero restore logs "$RESTORE_NAME"
        exit 1
    elif [ "$RESTORE_STATUS" == "InProgress" ]; then
        echo "Restore $RESTORE_NAME is still in progress..."
    else
        echo "Unexpected restore status: $RESTORE_STATUS"
    fi

    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    if [ $elapsed -ge $TIMEOUT ]; then
        echo "Timeout reached. Restore $RESTORE_NAME is still in progress."
        exit 1
    fi

    sleep $INTERVAL
done
