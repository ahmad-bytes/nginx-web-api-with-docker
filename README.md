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
