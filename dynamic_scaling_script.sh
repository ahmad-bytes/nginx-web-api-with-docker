#!/bin/bash

# Dynamic Scaling Script for NGINX Load Balancer
# Adds/removes API instances dynamically without downtime

set -e

NGINX_CONTAINER="weather-nginx-lb"
NETWORK_NAME="weather-api-network"
BASE_IMAGE="weather-api"
NGINX_CONFIG="nginx.conf"
BACKUP_CONFIG="nginx.conf.backup"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Get next available instance number
get_next_instance_number() {
    local max_num=0
    for container in $(docker ps --filter "name=weather-api-" --format "{{.Names}}"); do
        if [[ $container =~ weather-api-([0-9]+) ]]; then
            num=${BASH_REMATCH[1]}
            if [ $num -gt $max_num ]; then
                max_num=$num
            fi
        fi
    done
    echo $((max_num + 1))
}

# Get next available port
get_next_port() {
    local base_port=8081
    local max_port=$base_port
    
    for container in $(docker ps --filter "name=weather-api-" --format "{{.Names}}"); do
        local port=$(docker port $container 2>/dev/null | grep ":8080" | cut -d: -f2)
        if [[ $port =~ ^[0-9]+$ ]] && [ $port -gt $max_port ]; then
            max_port=$port
        fi
    done
    echo $((max_port + 1))
}

# Get current instances from NGINX config
get_current_instances() {
    grep -E "server weatherapi-[0-9]+:8080" $NGINX_CONFIG | grep -o "weatherapi-[0-9]\+" | sort -V
}

# Add new instance to NGINX config
add_to_nginx_config() {
    local instance_name=$1
    local temp_config="nginx.conf.tmp"
    
    # Backup current config
    cp $NGINX_CONFIG $BACKUP_CONFIG
    
    # Add new server to upstream block
    awk -v instance="$instance_name" '
    /server weatherapi-[0-9]+:8080.*weight=1;/ {
        print $0
        print "        server " instance ":8080 max_fails=3 fail_timeout=30s weight=1;"
        next
    }
    { print }
    ' $NGINX_CONFIG > $temp_config
    
    mv $temp_config $NGINX_CONFIG
}

# Remove instance from NGINX config
remove_from_nginx_config() {
    local instance_name=$1
    local temp_config="nginx.conf.tmp"
    
    # Backup current config
    cp $NGINX_CONFIG $BACKUP_CONFIG
    
    # Remove server from upstream block
    grep -v "server $instance_name:8080" $NGINX_CONFIG > $temp_config
    mv $temp_config $NGINX_CONFIG
}

# Test NGINX configuration
test_nginx_config() {
    if docker exec $NGINX_CONTAINER nginx -t 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Reload NGINX configuration
reload_nginx() {
    print_status "Reloading NGINX configuration..."
    if docker exec $NGINX_CONTAINER nginx -s reload; then
        print_success "NGINX configuration reloaded"
        return 0
    else
        print_error "Failed to reload NGINX configuration"
        return 1
    fi
}

# Rollback NGINX configuration
rollback_nginx_config() {
    print_warning "Rolling back NGINX configuration..."
    if [ -f $BACKUP_CONFIG ]; then
        cp $BACKUP_CONFIG $NGINX_CONFIG
        reload_nginx
    fi
}

# Add new API instance
add_instance() {
    local instance_num=$(get_next_instance_number)
    local instance_name="weatherapi-$instance_num"
    local container_name="weather-api-$instance_num"
    local host_port=$(get_next_port)
    
    print_status "Adding new API instance: $container_name"
    print_status "Instance will be available on port $host_port"
    
    # Create log directory
    mkdir -p "logs/api-$instance_num"
    
    # Start new container
    print_status "Starting container $container_name..."
    docker run -d \
        --name $container_name \
        --network $NETWORK_NAME \
        -p $host_port:8080 \
        -e ASPNETCORE_ENVIRONMENT=Production \
        -e ASPNETCORE_URLS=http://+:8080 \
        -e CONTAINER_NAME=$container_name \
        -e SERVER_INSTANCE=WeatherAPI-Instance-$instance_num \
        -v "$(pwd)/logs/api-$instance_num:/app/logs" \
        --restart unless-stopped \
        --health-cmd="curl -f http://localhost:8080/ || exit 1" \
        --health-interval=30s \
        --health-timeout=10s \
        --health-retries=3 \
        --health-start-period=40s \
        $BASE_IMAGE
    
    if [ $? -ne 0 ]; then
        print_error "Failed to start container $container_name"
        return 1
    fi
    
    print_success "Container $container_name started"
    
    # Wait for container to be healthy
    print_status "Waiting for container to be healthy..."
    local max_wait=60
    local wait_time=0
    
    while [ $wait_time -lt $max_wait ]; do
        if docker exec $container_name curl -f http://localhost:8080/ >/dev/null 2>&1; then
            print_success "Container $container_name is healthy"
            break
        fi
        sleep 2
        wait_time=$((wait_time + 2))
        echo -n "."
    done
    echo
    
    if [ $wait_time -ge $max_wait ]; then
        print_error "Container $container_name failed health check"
        docker stop $container_name
        docker rm $container_name
        return 1
    fi
    
    # Add to NGINX configuration
    print_status "Adding $instance_name to NGINX configuration..."
    add_to_nginx_config $instance_name
    
    # Test configuration
    if ! test_nginx_config; then
        print_error "NGINX configuration test failed"
        rollback_nginx_config
        docker stop $container_name
        docker rm $container_name
        return 1
    fi
    
    # Reload NGINX
    if ! reload_nginx; then
        print_error "Failed to reload NGINX"
        rollback_nginx_config
        docker stop $container_name
        docker rm $container_name
        return 1
    fi
    
    print_success "Successfully added instance $container_name"
    print_status "Direct access: http://localhost:$host_port/api/weather"
    print_status "Load balanced: http://localhost/api/weather"
    
    # Test new instance
    print_status "Testing new instance..."
    if curl -f -s http://localhost:$host_port/api/weather >/dev/null; then
        print_success "New instance is responding correctly"
    else
        print_warning "New instance is not responding properly"
    fi
    
    # Show current status
    show_status
}

# Remove API instance
remove_instance() {
    local instance_identifier=$1
    
    if [ -z "$instance_identifier" ]; then
        print_error "Please specify instance number or container name"
        echo "Usage: $0 remove <instance_number|container_name>"
        return 1
    fi
    
    # Determine container name and instance name
    local container_name
    local instance_name
    
    if [[ $instance_identifier =~ ^[0-9]+$ ]]; then
        # It's a number
        container_name="weather-api-$instance_identifier"
        instance_name="weatherapi-$instance_identifier"
    else
        # It's a container name
        container_name=$instance_identifier
        if [[ $container_name =~ weather-api-([0-9]+) ]]; then
            local num=${BASH_REMATCH[1]}
            instance_name="weatherapi-$num"
        else
            print_error "Invalid container name format"
            return 1
        fi
    fi
    
    # Check if container exists
    if ! docker ps -q --filter "name=^${container_name}$" | grep -q .; then
        print_error "Container $container_name not found"
        return 1
    fi
    
    print_status "Removing API instance: $container_name"
    
    # Remove from NGINX configuration first
    print_status "Removing $instance_name from NGINX configuration..."
    remove_from_nginx_config $instance_name
    
    # Test configuration
    if ! test_nginx_config; then
        print_error "NGINX configuration test failed"
        rollback_nginx_config
        return 1
    fi
    
    # Reload NGINX
    if ! reload_nginx; then
        print_error "Failed to reload NGINX"
        rollback_nginx_config
        return 1
    fi
    
    print_success "Instance removed from load balancer"
    
    # Wait a moment for connections to drain
    print_status "Waiting for connections to drain..."
    sleep 5
    
    # Stop and remove container
    print_status "Stopping container $container_name..."
    docker stop $container_name
    docker rm $container_name
    
    print_success "Successfully removed instance $container_name"
    
    # Show current status
    show_status
}

# Show current status
show_status() {
    echo
    print_status "Current Status:"
    echo "=============="
    
    # Running containers
    echo "Running API Instances:"
    docker ps --filter "name=weather-api-" --format "  {{.Names}} - {{.Ports}} - {{.Status}}"
    
    # NGINX configuration
    echo
    echo "NGINX Upstream Configuration:"
    get_current_instances | while read instance; do
        echo "  $instance"
    done
    
    # Health status
    echo
    echo "Health Status:"
    for container in $(docker ps --filter "name=weather-api-" --format "{{.Names}}"); do
        local port=$(docker port $container 2>/dev/null | grep ":8080" | cut -d: -f2)
        if curl -f -s http://localhost:$port/ >/dev/null 2>&1; then
            echo -e "  $container: ${GREEN}Healthy${NC}"
        else
            echo -e "  $container: ${RED}Unhealthy${NC}"
        fi
    done
    
    # Load balancer test
    echo
    echo "Load Balancer Test (10 requests):"
    for i in {1..10}; do
        curl -s http://localhost/api/weather >/dev/null && echo -n "✓" || echo -n "✗"
    done
    echo
}

# Auto-scale based on load
auto_scale() {
    local target_instances=$1
    local current_count=$(docker ps --filter "name=weather-api-" --format "{{.Names}}" | wc -l)
    
    print_status "Auto-scaling: Current instances: $current_count, Target: $target_instances"
    
    if [ $target_instances -gt $current_count ]; then
        local instances_to_add=$((target_instances - current_count))
        print_status "Scaling up: Adding $instances_to_add instances"
        
        for i in $(seq 1 $instances_to_add); do
            add_instance
            sleep 5  # Wait between additions
        done
    elif [ $target_instances -lt $current_count ]; then
        local instances_to_remove=$((current_count - target_instances))
        print_status "Scaling down: Removing $instances_to_remove instances"
        
        # Get highest numbered instances to remove
        local instances_to_remove_list=$(docker ps --filter "name=weather-api-" --format "{{.Names}}" | \
                                       grep -o '[0-9]\+$' | sort -nr | head -n $instances_to_remove)
        
        for instance_num in $instances_to_remove_list; do
            remove_instance $instance_num
            sleep 5  # Wait between removals
        done
    else
        print_success "Already at target scale: $target_instances instances"
    fi
}

# Main script logic
case "${1:-}" in
    "add")
        add_instance
        ;;
    "remove")
        remove_instance $2
        ;;
    "status")
        show_status
        ;;
    "scale")
        if [ -z "$2" ]; then
            print_error "Please specify target number of instances"
            echo "Usage: $0 scale <number>"
            exit 1
        fi
        auto_scale $2
        ;;
    "test")
        print_status "Testing load distribution..."
        for i in {1..20}; do
            curl -s http://localhost/api/weather | grep -o "weather-api-[0-9]" || echo "no-instance-info"
        done | sort | uniq -c
        ;;
    *)
        echo "Dynamic Scaling Script for NGINX Load Balancer"
        echo "=============================================="
        echo "Usage: $0 {add|remove|status|scale|test}"
        echo
        echo "Commands:"
        echo "  add                     - Add a new API instance"
        echo "  remove <instance_num>   - Remove specific API instance"
        echo "  status                  - Show current status"
        echo "  scale <number>          - Scale to specific number of instances"
        echo "  test                    - Test load distribution"
        echo
        echo "Examples:"
        echo "  $0 add                  - Add one new instance"
        echo "  $0 remove 3             - Remove instance 3"
        echo "  $0 scale 8              - Scale to 8 total instances"
        echo "  $0 status               - Show current setup"
        echo "  $0 test                 - Test load balancing"
        exit 1
        ;;
esac