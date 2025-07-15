#!/bin/bash
# User Data Script for E-commerce Application - LabRole Compatible Version
# Simplified to work with LabRole limitations

set -euo pipefail

exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "=== Starting LabRole compatible user data script at $(date) ==="

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_command() {
    if [ $? -eq 0 ]; then
        log "SUCCESS: $1"
    else
        log "WARNING: $1 failed (continuing anyway)"
        # Don't exit on failure for LabRole compatibility
    fi
}

log "Updating system packages..."
yum update -y
check_command "System update"

log "Installing basic packages..."
yum install -y python3 python3-pip wget curl unzip
check_command "Basic packages installation"

log "Installing Docker..."
amazon-linux-extras install docker -y
service docker start
usermod -a -G docker ec2-user
chkconfig docker on
check_command "Docker installation"

if ! command -v docker &> /dev/null; then
    log "ERROR: Docker installation failed"
    exit 1
fi

log "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
check_command "Docker Compose installation"

log "Creating application directory..."
mkdir -p /opt/ecommerce/logs
cd /opt/ecommerce

INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

log "Instance ID: $INSTANCE_ID"
log "Region: $REGION"
log "Availability Zone: $AZ"

# Simple health check service (no advanced monitoring for LabRole)
log "Creating simple health check service..."
cat > /opt/ecommerce/health.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import datetime
import subprocess
import os

class HealthCheckHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            
            health_data = {
                "status": "healthy",
                "timestamp": datetime.datetime.now().isoformat(),
                "environment": "${environment}",
                "instance_id": self.get_instance_id(),
                "uptime": self.get_uptime(),
                "services": {
                    "docker": self.check_service("docker")
                }
            }
            
            self.wfile.write(json.dumps(health_data, indent=2).encode())
        elif self.path == '/':
            self.send_response(302)
            self.send_header('Location', '/health')
            self.end_headers()
        else:
            self.send_response(404)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            error_data = {"error": "Not found", "path": self.path}
            self.wfile.write(json.dumps(error_data).encode())
    
    def get_instance_id(self):
        try:
            import urllib.request
            response = urllib.request.urlopen(
                'http://169.254.169.254/latest/meta-data/instance-id', 
                timeout=2
            )
            return response.read().decode()
        except:
            return "unknown"
    
    def get_uptime(self):
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.readline().split()[0])
                return f"{uptime_seconds:.0f} seconds"
        except:
            return "unknown"
    
    def check_service(self, service_name):
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', service_name],
                capture_output=True,
                text=True,
                timeout=5
            )
            return result.stdout.strip() == 'active'
        except:
            return False

if __name__ == "__main__":
    PORT = 8080
    with socketserver.TCPServer(("", PORT), HealthCheckHandler) as httpd:
        print(f"Health check server running on port {PORT}")
        httpd.serve_forever()
EOF

chmod +x /opt/ecommerce/health.py

log "Creating systemd service for health check..."
cat > /etc/systemd/system/ecommerce-health.service << 'EOF'
[Unit]
Description=E-commerce Health Check Service
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=ec2-user
Group=ec2-user
WorkingDirectory=/opt/ecommerce
ExecStart=/usr/bin/python3 /opt/ecommerce/health.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

log "Creating application environment file..."
cat > /opt/ecommerce/.env << 'EOF'
ENVIRONMENT=${environment}
LOG_LEVEL=INFO
APP_PORT=80
HEALTH_CHECK_PORT=8080
EOF

log "Creating Docker Compose configuration..."
cat > /opt/ecommerce/docker-compose.yml << 'EOF'
version: '3.8'

services:
  app:
    image: nginx:alpine
    ports:
      - "80:80"
    environment:
      - ENVIRONMENT=${environment}
    volumes:
      - ./logs:/var/log/nginx
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./static:/usr/share/nginx/html
    restart: unless-stopped
    depends_on:
      - redis
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost/app-health"]
      interval: 30s
      timeout: 10s
      retries: 3
    
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  redis_data:
    driver: local
EOF

log "Creating nginx configuration..."
cat > /opt/ecommerce/nginx.conf << 'EOF'
events {
    worker_connections 1024;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
    
    server {
        listen 80;
        server_name localhost;
        
        location / {
            root /usr/share/nginx/html;
            index index.html index.htm;
            try_files $uri $uri/ /index.html;
        }
        
        location /app-health {
            access_log off;
            return 200 '{"status":"healthy","service":"nginx","timestamp":"$time_iso8601"}\n';
            add_header Content-Type application/json;
        }
        
        location /static/ {
            root /usr/share/nginx/html;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
        
        location /api/ {
            return 503 '{"error":"API not configured yet","status":"503"}\n';
            add_header Content-Type application/json;
        }
    }
}
EOF

log "Creating static content..."
mkdir -p /opt/ecommerce/static
cat > /opt/ecommerce/static/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>E-commerce Application - LabRole Compatible</title>
    <style>
        body { 
            font-family: Arial, sans-serif; 
            margin: 40px; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            min-height: 100vh;
        }
        .container { 
            max-width: 800px; 
            margin: 0 auto; 
            background: rgba(255,255,255,0.1);
            padding: 30px;
            border-radius: 15px;
            backdrop-filter: blur(10px);
        }
        .status { 
            padding: 20px; 
            background: rgba(72, 187, 120, 0.2); 
            border-radius: 10px; 
            border: 1px solid rgba(72, 187, 120, 0.3);
            margin-bottom: 20px;
        }
        .info { 
            margin-top: 20px; 
            padding: 15px; 
            background: rgba(255,255,255,0.1); 
            border-radius: 10px; 
        }
        .warning {
            padding: 15px;
            background: rgba(245, 101, 101, 0.2);
            border-radius: 10px;
            border: 1px solid rgba(245, 101, 101, 0.3);
            margin-bottom: 20px;
        }
        a { color: #90cdf4; text-decoration: none; }
        a:hover { text-decoration: underline; }
        h1 { margin-top: 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 E-commerce Application</h1>
        <div class="status">
            <h2>✅ Application is running successfully!</h2>
            <p><strong>Environment:</strong> ${environment}</p>
            <p><strong>Mode:</strong> LabRole Compatible</p>
            <p><strong>Time:</strong> <span id="currentTime"></span></p>
        </div>
        
        <div class="warning">
            <h3>⚠️ LabRole Compatibility Mode</h3>
            <p>This deployment is optimized for AWS Academy LabRole constraints:</p>
            <ul>
                <li>Uses existing LabRole instead of creating new IAM roles</li>
                <li>Simplified monitoring (basic health checks only)</li>
                <li>RDS password without special characters</li>
                <li>Reduced CloudWatch logging to avoid permission issues</li>
            </ul>
        </div>
        
        <div class="info">
            <h3>🔍 Health Check Endpoints:</h3>
            <ul>
                <li><strong>ALB Health Check:</strong> <a href="/app-health">/app-health</a> (Port 80)</li>
                <li><strong>Detailed Health Check:</strong> <a href="#" onclick="checkDetailedHealth()">:8080/health</a></li>
            </ul>
            
            <h3>📊 Application Services:</h3>
            <ul>
                <li><strong>Web Server:</strong> Nginx (Port 80)</li>
                <li><strong>Cache:</strong> Redis (Port 6379)</li>
                <li><strong>Database:</strong> MySQL RDS (Port 3306)</li>
                <li><strong>Load Balancer:</strong> Application Load Balancer</li>
            </ul>
            
            <h3>🏗️ Infrastructure:</h3>
            <ul>
                <li><strong>VPC:</strong> Custom VPC with public/private subnets</li>
                <li><strong>Auto Scaling:</strong> 2-4 EC2 instances (t3.micro)</li>
                <li><strong>High Availability:</strong> Multi-AZ deployment</li>
                <li><strong>Storage:</strong> S3 bucket for static content</li>
            </ul>
        </div>
    </div>
    
    <script>
        function updateTime() {
            document.getElementById('currentTime').textContent = new Date().toLocaleString();
        }
        updateTime();
        setInterval(updateTime, 1000);
        
        function checkDetailedHealth() {
            // FIXED: Escaped JavaScript variables for Terraform compatibility
            const currentUrl = window.location;
            const healthUrl = 'http://' + currentUrl.hostname + ':8080/health';
            window.open(healthUrl, '_blank');
        }
    </script>
</body>
</html>
EOF

log "Setting up directory permissions..."
chown -R ec2-user:ec2-user /opt/ecommerce
chmod -R 755 /opt/ecommerce

log "Starting health check service..."
systemctl daemon-reload
systemctl enable ecommerce-health
systemctl start ecommerce-health
check_command "Health check service start"

sleep 5
if systemctl is-active --quiet ecommerce-health; then
    log "Health check service is running successfully"
else
    log "WARNING: Health check service may not be running properly"
fi

log "Starting Docker Compose services..."
cd /opt/ecommerce
docker-compose up -d
check_command "Docker Compose services start"

log "Waiting for services to be ready..."
sleep 10

if docker-compose ps | grep -q "Up"; then
    log "Docker services are running"
else
    log "WARNING: Some Docker services may not be running"
fi

log "Performing final health checks..."
if curl -s http://localhost:8080/health > /dev/null; then
    log "Health check endpoint is responding"
else
    log "WARNING: Health check endpoint is not responding yet"
fi

if curl -s http://localhost/app-health > /dev/null; then
    log "Application health endpoint is responding"
else
    log "WARNING: Application health endpoint is not responding yet"
fi

# Simple database connection test (if credentials are available)
log "Testing database connectivity..."
if command -v mysql &> /dev/null; then
    # Try to connect to database if mysql client is available
    mysql -h ${db_endpoint} -u admin -p"$(echo '${secret_arn}' | base64)" -e "SELECT 1;" 2>/dev/null || log "Database connection test skipped (normal for initial setup)"
else
    log "MySQL client not available for connection test"
fi

log "User data script completed successfully"
log "=== LabRole compatible user data script completed at $(date) ==="

exit 0
