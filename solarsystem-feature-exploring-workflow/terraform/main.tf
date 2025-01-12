# main.tf

provider "aws" {
  region = "us-east-1"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}
data "aws_availability_zones" "available" {}

# Backend configuration to store state in S3 and use DynamoDB for locking
terraform {
  backend "s3" {
    bucket         = "my-depi-anmz-terraform-state-bucket"    # Replace with your S3 bucket name
    key            = "terraform/state.tfstate"      # Path to the state file within the bucket
    region         = "us-east-1"                # AWS region -Variables not allowed
    dynamodb_table = "terraform-locks"              # DynamoDB table for state locking
    encrypt        = true                           # Encrypt state file at rest
  }
}

# VPC
resource "aws_vpc" "main_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true

  tags = {
    Name = "${var.environment_name} - VPC"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "${var.environment_name} - IGW"
  }
}

# Public Subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = var.public_subnet_1_cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.environment_name} Public Subnet (AZ1)"
  }
}



# Private Subnets
resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = var.private_subnet_1_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.environment_name} Private Subnet (AZ1)"
  }
}


# Route Tables
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.environment_name} Public Routes"
  }
}

resource "aws_route_table_association" "public_subnet_1_association" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_route_table.id
}


resource "aws_route_table" "private_route_table_1" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "${var.environment_name} Private Routes (AZ1)"
  }
}


resource "aws_route_table_association" "private_subnet_1_association" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_route_table_1.id
}

resource "aws_eip" "webserver_eip" {
  instance = aws_instance.fe_ec2.id
  domain = "vpc"
}
resource "aws_instance" "fe_ec2" {
  ami           = var.ec2_ami
  instance_type = var.ec2_type
  subnet_id = aws_subnet.public_subnet_1.id
  key_name      = "ec2_key_pair"
  vpc_security_group_ids = [aws_security_group.web_sec_group.id]
  
  
  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update -y
    sudo apt-get install apache2 -y
    sudo systemctl start apache2.service
    cd /var/www/html
    sudo rm index.html
    sudo ufw allow 80/tcp
    #echo "it works! Depi, MCIT" > index.html
  EOF

  root_block_device {
    volume_size = 10
  }
  depends_on = [aws_security_group.web_sec_group]
   
}



# Security Group for Web Server
resource "aws_security_group" "web_sec_group" {
  description = "Allow http to our hosts and SSH from local only"
  vpc_id      = aws_vpc.main_vpc.id
  

  

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "WebServer"
  }
  
}


# Security Group for Prometheus and Grafana Server
resource "aws_security_group" "monitoring_sec_group" {
  description = "Allow HTTP, HTTPS, and SSH traffic"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 3000  # Grafana
    to_port     = 3000
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 9090  # Prometheus
    to_port     = 9090
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-MonitoringSecurityGroup"
  }
}

# EC2 Instance for Prometheus and Grafana Server
resource "aws_instance" "monitoring_server" {
  ami           = var.ec2_ami
  instance_type = var.ec2_type
  subnet_id = aws_subnet.public_subnet_1.id
  key_name      = "ec2_key_pair"  
  vpc_security_group_ids = [aws_security_group.monitoring_sec_group.id]
  
  root_block_device {
    volume_size = 20
  }
  
  tags = {
    Name = "PrometheusServer"
  }
  depends_on = [aws_security_group.monitoring_sec_group]
}

# Elastic IP for the Monitoring Server
resource "aws_eip" "monitoring_server_eip" {
  instance = aws_instance.monitoring_server.id
  domain = "vpc"
}

# Generate RSA private key locally
resource "tls_private_key" "rsa-4096-pem" {
  algorithm = "RSA"
  rsa_bits = 4096

}

# Create AWS Key Pair by uploading the generated public key
# Create a key pair resource to use during instance provisioning
resource "aws_key_pair" "ec2_key_pair" {
  key_name   = "ec2_key_pair"
  public_key = tls_private_key.rsa-4096-pem.public_key_openssh

}



resource "local_file" "ec2_key_pair_private_key_pem" {
  content = tls_private_key.rsa-4096-pem.private_key_pem
  filename = "ec2privkeypem"
}

# provisioning k3s ec2
resource "aws_instance" "k3s_ec2" {
  ami           = var.ec2_ami
  instance_type = "t2.small"
  subnet_id = aws_subnet.public_subnet_1.id
  key_name      = "ec2_key_pair"
  vpc_security_group_ids = [aws_security_group.k3s_sec_group.id]
  user_data = <<-EOF
    #!/bin/bash
    # Update and install necessary packages
    sudo apt-get update -y
    sudo setenforce 0
    sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
    sudo ufw allow 22/tcp
    sudo ufw allow 6443/tcp
    sudo ufw allow 8472/udp
    sudo ufw allow 10250/tcp
    sudo ufw allow 10255/tcp
    sudo ufw allow 3000/tcp
    sudo ufw allow 3001/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 8080/tcp
  EOF
  root_block_device {
    volume_size = 30
  }

  tags = {
    Name = "K3s-Node"
  }
  depends_on = [aws_security_group.k3s_sec_group]
}

resource "aws_eip" "k3s_server_eip" {
  instance = aws_instance.k3s_ec2.id
  domain = "vpc"
}
 
# Security Group for Prometheus and Grafana Server
resource "aws_security_group" "k3s_sec_group" {
  description = "Allow HTTP, solarsystem port, and SSH traffic"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    protocol    = "tcp"
    from_port   = 3000  # testing
    to_port     = 3000
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 3001  # staging env
    to_port     = 3001
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-K3sSecurityGroup"
  }
}