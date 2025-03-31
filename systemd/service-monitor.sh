#!/usr/bin/env bash

# Function to get list of port services
get_port_services() {
    find /etc/systemd/system -name "port[0-9]*.service" -exec basename {} .service \;
}

# Function to check and restart service if needed
check_service() {
    local service=$1

    # Check if service is active
    if ! systemctl is-active --quiet "${service}.service"; then
        logger -p warning "[service-monitor] ${service}.service is down. Attempting to restart..."

        if systemctl restart "${service}.service"; then
            logger -p notice "[service-monitor] Successfully restarted ${service}.service"
        else
            logger -p err "[service-monitor] Failed to restart ${service}.service"
            systemctl status "${service}.service" | logger -p err
        fi
    else
        logger -p info "[service-monitor] ${service}.service is running"
    fi
}

# Function to check all services
check_all_services() {
    local services
    services=$(get_port_services)

    for service in $services; do
        check_service "$service"
    done
}

# Main loop
while true; do
    logger -p info "[service-monitor] Starting service check..."
    check_all_services
    logger -p info "[service-monitor] Completed service check. Waiting 5 seconds before next check..."
    sleep 5
done
