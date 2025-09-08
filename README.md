# Create log directories
mkdir -p logs/{api-1,api-2,api-3,api-4,api-5,nginx}

# Launch all services
docker-compose -f docker-compose-nginx.yml up -d --build

# Verify all running
docker-compose ps

# Test load balancing
for i in {1..25}; do
  curl -s http://localhost/api/weather | grep -o "weather-api-[0-9]"
done | sort | uniq -c


IF (CPU > 70% OR Response_Time > 1s OR Requests_Per_Instance > 50)
   AND (Not in cooldown period)
   AND (Current_Instances < Max_Instances)
THEN Scale_Up()

IF (CPU < 30% AND Response_Time < 0.5s AND Requests_Per_Instance < 25)
   AND (Not in cooldown period) 
   AND (Current_Instances > Min_Instances)
THEN Scale_Down()

# Basic Auto Scaling
# Start with 5 instances
docker-compose -f docker-compose-nginx.yml up -d --build

# Make scaling script executable
chmod +x dynamic-scaling.sh

# Add 2 more instances
./dynamic-scaling.sh add
./dynamic-scaling.sh add

# Check current setup
./dynamic-scaling.sh status
# Output shows: 7 running instances with health status

# Scale to 10 instances
./dynamic-scaling.sh scale 10

# Test load distribution
./dynamic-scaling.sh test
# Shows requests distributed across all 10 instances

# Start auto-scaling monitor
chmod +x auto-scaling-monitor.sh
nohup ./auto-scaling-monitor.sh start > auto-scaling.log 2>&1 &

# Monitor real-time
tail -f auto-scaling.log

# Check status
./auto-scaling-monitor.sh status

