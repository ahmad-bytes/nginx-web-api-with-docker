#!/bin/bash

# Auto-Scaling Monitor for NGINX Load Balancer
# Monitors load and automatically scales instances based on metrics

set -e

# Configuration
SCALE_SCRIPT="./dynamic-scaling.sh"
LOG_FILE="auto-scaling-$(date +%Y%m%d_%H%M%S).log"
CHECK_INTERVAL=30  # seconds
MIN_INSTANCES=2
MAX_INSTANCES=10

# Thresholds
CPU_SCALE_UP_THRESHOLD=70    # Scale up if average CPU > 70%
CPU_SCALE_DOWN_THRESHOLD=30  # Scale down if average CPU < 30%
RESPONSE_TIME_THRESHOLD=1.0  # Scale up if avg response time > 1 second
REQUEST_RATE_THRESHOLD=50    # Scale up if requests/min > 50 per instance

# Scaling constraints
SCALE_UP_COOLDOWN=180       # Wait 3 minutes before scaling up again
SCALE_DOWN_COOLDOWN=300     # Wait 5 minutes before scaling down again
LAST_SCALE_TIME=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_message() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a $LOG_FILE
}

log_action() {
    echo -e "${GREEN}[ACTION]${NC} $1" | tee -a $LOG_FILE
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a $LOG_FILE
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a $LOG_FILE
}

# Get current number of instances
get_instance_count() {
    docker ps --filter "name=weather-api-" --format "{{.Names}}" | wc -l
}

# Get average CPU usage across all API instances
get_average_cpu() {
    local total_cpu=0
    local count=0
    
    for container in $(docker ps --filter "name=weather-api-" --format "{{.Names}}"); do
        local cpu=$(docker stats --no-stream --format "{{.CPUPerc}}" $container | sed 's/%//')
        if [[ $cpu =~ ^[0-9]+\.?[0-9]*$ ]]; then
            total_cpu=$(echo "$total_cpu + $cpu" | bc -l)
            ((count++))
        fi
    done
    
    if [ $count -gt 0 ]; then
        echo "scale=2; $total_cpu / $count" | bc -l
    else
        echo "0"
    fi
}

# Get average response time from NGINX logs
get_average_response_time() {
    # Get last 50 requests from NGINX logs
    tail -n 50 logs/nginx/access.log 2>/dev/null | \
    grep -o 'rt=[0-9.]*' | cut -d= -f2 | \
    awk '{sum+=$1; count++} END {if(count>0) printf "%.3f", sum/count; else print "0"}'
}

# Get request rate (requests per minute)
get_request_rate() {
    # Count requests in last minute
    local one_minute_ago=$(date -d '1 minute ago' '+%d/%b/%Y:%H:%M')
    local current_minute=$(date '+%d/%b/%Y:%H:%M')
    
    grep -c "\[$one_minute_ago\|$current_minute" logs/nginx/access.log 2>/dev/null || echo "0"
}

# Get request rate per instance
get_request_rate_per_instance() {
    local total_rate=$(get_request_rate)
    local instance_count=$(get_instance_count)
    
    if [ $instance_count -gt 0 ]; then
        echo "scale=2; $total_rate / $instance_count" | bc -l
    else
        echo "0"
    fi
}

# Check if we're in cooldown period
in_cooldown() {
    local current_time=$(date +%s)
    local time_since_last_scale=$((current_time - LAST_SCALE_TIME))
    
    if [ $time_since_last_scale -lt $1 ]; then
        return 0  # In cooldown
    else
        return 1  # Not in cooldown
    fi
}

# Scale up instances
scale_up() {
    local current_instances=$(get_instance_count)
    local target_instances=$((current_instances + 1))
    
    if [ $target_instances -gt $MAX_INSTANCES ]; then
        log_warning "Cannot scale up: already at maximum instances ($MAX_INSTANCES)"
        return 1
    fi
    
    if in_cooldown $SCALE_UP_COOLDOWN; then
        log_warning "Scale up in cooldown period"
        return 1
    fi
    
    log_action "Scaling UP: $current_instances -> $target_instances instances"
    
    if $SCALE_SCRIPT add; then
        LAST_SCALE_TIME=$(date +%s)
        log_action "Successfully scaled up to $target_instances instances"
        return 0
    else
        log_error "Failed to scale up"
        return 1
    fi
}

# Scale down instances
scale_down() {
    local current_instances=$(get_instance_count)
    local target_instances=$((current_instances - 1))
    
    if [ $target_instances -lt $MIN_INSTANCES ]; then
        log_warning "Cannot scale down: already at minimum instances ($MIN_INSTANCES)"
        return 1
    fi
    
    if in_cooldown $SCALE_DOWN_COOLDOWN; then
        log_warning "Scale down in cooldown period"
        return 1
    fi
    
    log_action "Scaling DOWN: $current_instances -> $target_instances instances"
    
    # Find highest numbered instance to remove
    local highest_instance=$(docker ps --filter "name=weather-api-" --format "{{.Names}}" | \
                           grep -o '[0-9]\+$' | sort -nr | head -n 1)
    
    if $SCALE_SCRIPT remove $highest_instance; then
        LAST_SCALE_TIME=$(date +%s)
        log_action "Successfully scaled down to $target_instances instances"
        return 0
    else
        log_error "Failed to scale down"
        return 1
    fi
}

# Evaluate scaling decision
evaluate_scaling() {
    local current_instances=$(get_instance_count)
    local avg_cpu=$(get_average_cpu)
    local avg_response_time=$(get_average_response_time)
    local request_rate=$(get_request_rate)
    local request_rate_per_instance=$(get_request_rate_per_instance)
    
    log_message "Metrics: Instances=$current_instances, CPU=${avg_cpu}%, RT=${avg_response_time}s, Rate=${request_rate}/min (${request_rate_per_instance}/instance)"
    
    # Determine if we should scale up
    local should_scale_up=false
    local scale_up_reasons=()
    
    if (( $(echo "$avg_cpu > $CPU_SCALE_UP_THRESHOLD" | bc -l) )); then
        should_scale_up=true
        scale_up_reasons+=("CPU: ${avg_cpu}% > ${CPU_SCALE_UP_THRESHOLD}%")
    fi
    
    if (( $(echo "$avg_response_time > $RESPONSE_TIME_THRESHOLD" | bc -l) )); then
        should_scale_up=true
        scale_up_reasons+=("Response time: ${avg_response_time}s > ${RESPONSE_TIME_THRESHOLD}s")
    fi
    
    if (( $(echo "$request_rate_per_instance > $REQUEST_RATE_THRESHOLD" | bc -l) )); then
        should_scale_up=true
        scale_up_reasons+=("Request rate: ${request_rate_per_instance}/min per instance > ${REQUEST_RATE_THRESHOLD}/min")
    fi
    
    # Determine if we should scale down
    local should_scale_down=false
    local scale_down_reasons=()
    
    if (( $(echo "$avg_cpu < $CPU_SCALE_DOWN_THRESHOLD" | bc -l) )); then
        if (( $(echo "$avg_response_time < $(echo "$RESPONSE_TIME_THRESHOLD * 0.5" | bc -l)" | bc -l) )); then
            if (( $(echo "$request_rate_per_instance < $(echo "$REQUEST_RATE_THRESHOLD * 0.5" | bc -l)" | bc -l) )); then
                should_scale_down=true
                scale_down_reasons+=("Low load: CPU=${avg_cpu}%, RT=${avg_response_time}s, Rate=${request_rate_per_instance}/min per instance")
            fi
        fi
    fi
    
    # Execute scaling decisions
    if [ "$should_scale_up" = true ]; then
        log_message "Scale up triggered: ${scale_up_reasons[*]}"
        scale_up
    elif [ "$should_scale_down" = true ] && [ $current_instances -gt $MIN_INSTANCES ]; then
        log_message "Scale down triggered: ${scale_down_reasons[*]}"
        scale_down
    else
        log_message "No scaling action needed"
    fi
}

# Health check and recovery
health_check() {
    local unhealthy_instances=()
    
    for container in $(docker ps --filter "name=weather-api-" --format "{{.Names}}"); do
        local port=$(docker port $container 2>/dev/null | grep ":8080" | cut -d: -f2)
        if ! curl -f -s http://localhost:$port/ >/dev/null 2>&1; then
            unhealthy_instances+=($container)
        fi
    done
    
    if [ ${#unhealthy_instances[@]} -gt 0 ]; then
        log_warning "Unhealthy instances detected: ${unhealthy_instances[*]}"
        
        for container in "${unhealthy_instances[@]}"; do
            log_action "Attempting to restart unhealthy instance: $container"
            docker restart $container
            
            # Wait for restart
            sleep 30
            
            # Check again
            local port=$(docker port $container 2>/dev/null | grep ":8080" | cut -d: -f2)
            if curl -f -s http://localhost:$port/ >/dev/null 2>&1; then
                log_action "Successfully restarted $container"
            else
                log_error "Failed to restart $container - removing from load balancer"
                # Extract instance number and remove
                if [[ $container =~ weather-api-([0-9]+) ]]; then
                    $SCALE_SCRIPT remove ${BASH_REMATCH[1]}
                fi
            fi
        done
    fi
}

# Signal handlers
cleanup() {
    log_message "Auto-scaling monitor stopping..."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main monitoring loop
main() {
    log_message "Starting auto-scaling monitor..."
    log_message "Configuration:"
    log_message "  Min instances: $MIN_INSTANCES"
    log_message "  Max instances: $MAX_INSTANCES"
    log_message "  Check interval: $CHECK_INTERVAL seconds"
    log_message "  CPU thresholds: Scale up >$CPU_SCALE_UP_THRESHOLD%, Scale down <$CPU_SCALE_DOWN_THRESHOLD%"
    log_message "  Response time threshold: $RESPONSE_TIME_THRESHOLD seconds"
    log_message "  Request rate threshold: $REQUEST_RATE_THRESHOLD requests/min per instance"
    log_message "  Log file: $LOG_FILE"
    
    while true; do
        # Health check first
        health_check
        
        # Wait a moment for things to settle
        sleep 5
        
        # Evaluate scaling
        evaluate_scaling
        
        # Wait for next check
        sleep $CHECK_INTERVAL
    done
}

# Command line options
case "${1:-}" in
    "start")
        main
        ;;
    "status")
        current_instances=$(get_instance_count)
        avg_cpu=$(get_average_cpu)
        avg_response_time=$(get_average_response_time)
        request_rate=$(get_request_rate)
        
        echo "Auto-Scaling Status:"
        echo "==================="
        echo "Current instances: $current_instances"
        echo "Average CPU: ${avg_cpu}%"
        echo "Average response time: ${avg_response_time}s"
        echo "Request rate: ${request_rate}/min"
        echo "Min instances: $MIN_INSTANCES"
        echo "Max instances: $MAX_INSTANCES"
        
        if [ -f $LOG_FILE ]; then
            echo
            echo "Recent actions:"
            tail -n 10 $LOG_FILE | grep -E "\[ACTION\]|\[WARNING\]|\[ERROR\]"
        fi
        ;;
    "logs")
        if [ -f $LOG_FILE ]; then
            tail -f $LOG_FILE
        else
            echo "No log file found"
            exit 1
        fi
        ;;
    "test")
        log_message "Testing scaling evaluation..."
        evaluate_scaling
        ;;
    *)
        echo "Auto-Scaling Monitor for NGINX Load Balancer"
        echo "==========================================="
        echo "Usage: $0 {start|status|logs|test}"
        echo
        echo "Commands:"
        echo "  start   - Start the auto-scaling monitor"
        echo "  status  - Show current scaling status"
        echo "  logs    - Follow the auto-scaling logs"
        echo "  test    - Test scaling evaluation once"
        echo
        echo "To run in background:"
        echo "  nohup $0 start > auto-scaling.out 2>&1 &"
        exit 1
        ;;
esac