#!/bin/bash

# Function to get list of port services
get_port_services() {
    # Find all port*.service files and strip .service extension
    find /etc/systemd/system -name "port[0-9]*.service" -exec basename {} .service \;
}

# Function to check and restart service if needed
check_service() {
    local service=$1
    
    # Check if service is active
    if ! systemctl is-active --quiet ${service}.service; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${service}.service is down. Attempting to restart..."
        
        # Try to restart the service
        if systemctl restart ${service}.service; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Successfully restarted ${service}.service"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed to restart ${service}.service" >&2
            
            # Get service status for debugging
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Service status:"
            systemctl status ${service}.service
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${service}.service is running"
    fi
}

# Function to check all services
check_all_services() {
    local services=$(get_port_services)
    
    for service in $services; do
        check_service "$service"
        echo "----------------------------------------"
    done
}

# Main loop
while true; do
    echo "=== Starting service check at $(date '+%Y-%m-%d %H:%M:%S') ==="
    check_all_services
    echo "=== Completed service check at $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo ""
    echo "Waiting 5 seconds before next check..."
    sleep 5
done
