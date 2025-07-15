 ============================================================================
# E-commerce Infrastructure with Terraform - LabRole Compatible Version
# ============================================================================

# Variables
variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
  default     = "dev"
}

variable "key_pair_name" {
  description = "Name of the EC2 Key Pair"
  type        = string
  default     = "ecommerce-production-key"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "ecommerce"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access ALB"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "min_instances" {
  description = "Minimum number of instances in ASG"
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of instances in ASG"
  type        = number
  default     = 3
}

variable "desired_instances" {
  description = "Desired number of instances in ASG"
  type        = number
  default     = 2
}

variable "enable_waf" {
  description = "Enable WAF for production environments"
  type        = bool
  default     = false
}

# Local values optimized for LabRole constraints
locals {
  nat_gateway_count = 1
  web_instance_type = "t3.micro"
  db_instance_class = "db.t3.micro"
  db_multi_az = false
  
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform-LabRole"
  }
}

# Provider configuration for LabRole
provider "aws" {
  region  = "us-east-1"
  profile = "lab"
}

# Random ID para recursos únicos
resource "random_id" "bucket" {
  byte_length = 4
}

# FIXED: Password compatible with RDS (no special characters)
resource "random_password" "db_password" {
  length  = 16
  special = false  # FIXED: Disable special characters for RDS compatibility
  upper   = true
  lower   = true
  numeric = true
}

# ============================================================================
# SECRETS MANAGER (Simplified for LabRole)
# ============================================================================

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}-db-password-${var.environment}-${random_id.bucket.hex}"
  description             = "Database password for ${var.project_name}"
  recovery_window_in_days = 0
  
  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.db_password.result
    engine   = "mysql"
    host     = aws_db_instance.mysql.endpoint
    port     = aws_db_instance.mysql.port
    dbname   = aws_db_instance.mysql.db_name
  })
  
  depends_on = [aws_db_instance.mysql]
}

# ============================================================================
# DATA SOURCES
# ============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# FIXED: Get existing LabRole instead of creating new one
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

# ============================================================================
# VPC AND NETWORKING
# ============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

# Public Subnets
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-${count.index + 1}"
    Type = "Public"
    Tier = "Web"
  })
}

# Private Subnets for Application
resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 4}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-app-${count.index + 1}"
    Type = "Private"
    Tier = "Application"
  })
}

# Private Subnets for Database
resource "aws_subnet" "private_db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 7}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-db-${count.index + 1}"
    Type = "Private"
    Tier = "Database"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  count  = 1
  domain = "vpc"
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat-eip"
  })
  
  depends_on = [aws_internet_gateway.gw]
}

# NAT Gateway
resource "aws_nat_gateway" "nat" {
  count         = 1
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nat"
  })
  
  depends_on = [aws_internet_gateway.gw]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Tables for Application Subnets
resource "aws_route_table" "private_app" {
  count  = 2
  vpc_id = aws_vpc.main.id
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-app-rt-${count.index + 1}"
  })
}

resource "aws_route" "private_app_nat" {
  count                  = 2
  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[0].id
}

resource "aws_route_table_association" "private_app" {
  count          = 2
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# Private Route Tables for Database Subnets
resource "aws_route_table" "private_db" {
  count  = 2
  vpc_id = aws_vpc.main.id
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-db-rt-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private_db" {
  count          = 2
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db[count.index].id
}

# ============================================================================
# SECURITY GROUPS
# ============================================================================

resource "aws_security_group" "alb_sg" {
  name_prefix = "${var.project_name}-alb-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Application Load Balancer"
  
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }
  
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }
  
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb-sg"
  })
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ec2_sg" {
  name_prefix = "${var.project_name}-ec2-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for EC2 instances"
  
  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  
  ingress {
    description     = "Health Check from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  
  ingress {
    description = "SSH (restricted to VPC)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ec2-sg"
  })
  
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "rds_sg" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for RDS MySQL"
  
  ingress {
    description     = "MySQL from EC2"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-rds-sg"
  })
  
  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# CLOUDWATCH LOGS (Simplified for LabRole)
# ============================================================================

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/ec2/${var.project_name}"
  retention_in_days = 7
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-logs"
  })
}

# ============================================================================
# LAUNCH TEMPLATE (Using existing LabRole)
# ============================================================================

resource "aws_launch_template" "web" {
  name_prefix   = "${var.project_name}-web-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = local.web_instance_type
  key_name      = var.key_pair_name
  
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  
  # FIXED: Use existing LabRole instead of creating new IAM role
  iam_instance_profile {
    name = "LabInstanceProfile"  # Common name for LabRole instance profile
  }
  
  monitoring {
    enabled = true
  }
  
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    http_put_response_hop_limit = 2
  }
  
  # FIXED: Simplified user_data without IAM dependencies
  user_data = base64encode(templatefile("${path.module}/user_data_simple.sh", {
    log_group_name = aws_cloudwatch_log_group.app_logs.name
    secret_arn     = aws_secretsmanager_secret.db_password.arn
    environment    = var.environment
    db_endpoint    = aws_db_instance.mysql.endpoint
  }))
  
  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-web-instance"
    })
  }
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-launch-template"
  })
  
  depends_on = [
    aws_db_instance.mysql,
    aws_secretsmanager_secret_version.db_password
  ]
}

# Auto Scaling Group
resource "aws_autoscaling_group" "web" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = aws_subnet.private_app[*].id
  desired_capacity    = var.desired_instances
  max_size            = var.max_instances
  min_size            = var.min_instances
  health_check_type   = "ELB"
  health_check_grace_period = 300
  
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
  
  target_group_arns = [aws_lb_target_group.web.arn]
  
  tag {
    key                 = "Name"
    value               = "${var.project_name}-web-asg"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }
  
  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
  
  tag {
    key                 = "ManagedBy"
    value               = "Terraform-LabRole"
    propagate_at_launch = true
  }
  
  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# APPLICATION LOAD BALANCER
# ============================================================================

resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
  
  enable_deletion_protection = false
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb"
  })
}

# Target Group
resource "aws_lb_target_group" "web" {
  name     = "${var.project_name}-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/app-health"
    matcher             = "200"
    port                = "traffic-port"
    protocol            = "HTTP"
  }
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-web-tg"
  })
  
  lifecycle {
    create_before_destroy = true
  }
}

# ALB Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-http-listener"
  })
}

# ============================================================================
# RDS DATABASE
# ============================================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = aws_subnet.private_db[*].id
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-db-subnet"
  })
}

resource "aws_db_instance" "mysql" {
  identifier                = "${var.project_name}-db"
  engine                    = "mysql"
  engine_version            = "8.0.35"
  instance_class            = local.db_instance_class
  allocated_storage         = 20
  max_allocated_storage     = 30
  storage_type              = "gp2"
  storage_encrypted         = true
  
  db_name  = "ecommerce"
  username = "admin"
  password = random_password.db_password.result  # FIXED: Now uses valid password
  
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  
  multi_az               = local.db_multi_az
  publicly_accessible    = false
  backup_retention_period = 1
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"
  
  skip_final_snapshot = true
  deletion_protection = false
  
  auto_minor_version_upgrade = true
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-mysql"
  })
  
  lifecycle {
    ignore_changes = [password]
  }
}

# ============================================================================
# S3 STORAGE
# ============================================================================

resource "aws_s3_bucket" "static" {
  bucket = "${var.project_name}-static-content-${random_id.bucket.hex}"
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-static"
  })
}

resource "aws_s3_bucket_versioning" "static" {
  bucket = aws_s3_bucket.static.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "static" {
  bucket = aws_s3_bucket.static.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================================
# CLOUDWATCH ALARMS (Simplified)
# ============================================================================

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.project_name}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }
  
  tags = merge(local.common_tags, {
    Name = "${var.project_name}-high-cpu-alarm"
  })
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "alb_url" {
  description = "Full URL of the Application Load Balancer"
  value       = "http://${aws_lb.alb.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.alb.dns_name
}

output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = aws_db_instance.mysql.endpoint
  sensitive   = true
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for static content"
  value       = aws_s3_bucket.static.bucket
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "key_pair_name" {
  description = "Name of the EC2 Key Pair used"
  value       = var.key_pair_name
}

output "lab_role_arn" {
  description = "ARN of the LabRole being used"
  value       = data.aws_iam_role.lab_role.arn
}

output "estimated_monthly_cost" {
  description = "Estimated monthly cost in USD (LabRole optimized)"
  value = {
    ec2_instances     = "${var.desired_instances}x t3.micro ≈ $${var.desired_instances * 8.5}"
    nat_gateway       = "1x NAT Gateway ≈ $45"
    rds_database      = "1x db.t3.micro ≈ $15"
    load_balancer     = "1x ALB ≈ $25"
    storage_logs      = "S3/CloudWatch ≈ $5"
    total_approx      = "≈ $${var.desired_instances * 8.5 + 45 + 15 + 25 + 5}"
    note              = "Optimized for LabRole constraints"
  }
}
