#!/bin/bash

set -e

function aws() {
  command aws --endpoint-url http://192.168.0.3:4566 "$@"
}

# Parse arguments
dry_run=false
retain_count=0

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dry-run) dry_run=true ;;
        --retain-count) retain_count="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [[ $retain_count -le 0 ]]; then
    echo "Error: --retain-count must be a positive integer."
    exit 1
fi

# List backups from S3
bucket="backups"
prefix="backups/"
backups=($(aws s3 ls s3://$bucket/$prefix | awk '{print $2}' | sed 's:/$::'))

# Ensure backups are sorted in descending order (newest first)
IFS=$'\n' backups=($(printf "%s\n" "${backups[@]}" | sort -r))

# Determine backups to delete
delete_count=$((${#backups[@]} - retain_count))
if [[ $delete_count -gt 0 ]]; then
    backups_to_delete=("${backups[@]:$retain_count}")
else
    backups_to_delete=()
fi

if [[ ${#backups_to_delete[@]} -eq 0 ]]; then
    echo "No backups to delete. Retaining ${#backups[@]} backups."
    exit 0
fi

# Print backups to delete
if [[ "$dry_run" == true ]]; then
    echo "Dry run enabled. The following backups would be deleted:"
    for backup in "${backups_to_delete[@]}"; do
        echo "$prefix$backup/"
    done
else
    echo "Deleting the following backups:"
    for backup in "${backups_to_delete[@]}"; do
        echo "$prefix$backup/"
        aws s3 rm --recursive s3://$bucket/$prefix$backup/
    done
fi
