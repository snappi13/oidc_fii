# ============================================================
# CloudPulse Infrastructure — Session 3
# ============================================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
//
provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


# ============================================================
# PHASE 1: Network — VPC + Subnet + Route table
# ============================================================


resource "aws_vpc" "cloudpulse" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "cloudpulse" {
  vpc_id = aws_vpc.cloudpulse.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.cloudpulse.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.cloudpulse.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cloudpulse.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}


# ============================================================
# PHASE 2: Security Group (module) + S3
# ============================================================
# NOTE: After uncommenting, run "terraform init" before apply
#       (required because the module is new)
# ============================================================

resource "aws_security_group" "cloudpulse_sg" {
  name        = "${var.project_name}-sg"
  description = "Allow SSH, HTTP, and App ports"
  vpc_id      = aws_vpc.cloudpulse.id
  # Standard SSH & HTTP
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 8089
    to_port     = 8089
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Custom Application Ports
  ingress {
    description = "Grafana / Apps"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # --- PRIVATE ACCESS (Self-Referencing) ---
  # These ports are only reachable BY the instances inside this SG.

  ingress {
    description = "Allow all internal traffic between cluster nodes"
    from_port   = 3000
    to_port     = 9999
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

resource "aws_s3_bucket" "cloudpulse" {
  bucket = "${var.s3_bucket_prefix}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  tags   = { Name = "${var.project_name}-assets" }
}

resource "aws_s3_object" "background" {
  bucket       = aws_s3_bucket.cloudpulse.id
  key          = var.background_image_key
  source       = var.background_image_path
  content_type = "image/jpeg"
}



# ============================================================
# PHASE 3: DynamoDB
# ============================================================


resource "aws_dynamodb_table" "cloudpulse" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST" # No capacity planning — you pay only for actual reads/writes
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = { Name = "${var.project_name}-counter" }
}

resource "aws_dynamodb_table_item" "visits" {
  table_name = aws_dynamodb_table.cloudpulse.name
  hash_key   = aws_dynamodb_table.cloudpulse.hash_key

  item = <<ITEM
{
  "id": {"S": "visits"},
  "count": {"N": "0"}
}
ITEM

  lifecycle {
    ignore_changes = [item]
  }
}



# ============================================================
# PHASE 4: IAM + EC2
# ============================================================


resource "aws_iam_role" "cloudpulse_ec2" {
  name = "${var.project_name}-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole", Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cloudpulse_access" {
  name = "${var.project_name}-access-policy"
  role = aws_iam_role.cloudpulse_ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.cloudpulse.arn,
        "${aws_s3_bucket.cloudpulse.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:UpdateItem",
        "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.cloudpulse.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "cloudpulse" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.cloudpulse_ec2.name
}

resource "aws_instance" "cloudpulse" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.cloudpulse_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.cloudpulse.name
  private_ip                  = "10.0.0.10"
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

    # 1. Install App dependencies
    yum update -y
    yum install -y python3-pip unzip
    pip3 install flask requests boto3 pytz prometheus-flask-exporter

    mkdir -p /home/ec2-user/app

    # 2. Inject the Flask app
    cat << 'PY_EOF' > /home/ec2-user/app/app.py
    ${templatefile("${path.module}/app.py.tftpl", {
  bucket_name = aws_s3_bucket.cloudpulse.bucket,
  table_name  = var.dynamodb_table_name,
  aws_region  = var.aws_region,
  image_key   = var.background_image_key
})}
    PY_EOF

    # 3. Setup Flask Service (Redirecting logs to a file for Promtail)
    cat <<SVC_EOF > /etc/systemd/system/cloudpulse.service
    [Unit]
    Description=CloudPulse Flask App
    After=network.target

    [Service]
    User=root
    WorkingDirectory=/home/ec2-user/app
    # Standard output/error redirected to app.log for Loki
    ExecStart=/usr/bin/python3 /home/ec2-user/app/app.py
    StandardOutput=append:/home/ec2-user/app/app.log
    StandardError=append:/home/ec2-user/app/app.log
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVC_EOF

    systemctl daemon-reload
    systemctl enable cloudpulse
    systemctl start cloudpulse

    # 4. Install Node Exporter (Metrics for Port 9100)
    wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
    tar xvfz node_exporter-1.7.0.linux-amd64.tar.gz
    cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
    
    cat <<NODE_EOF > /etc/systemd/system/node_exporter.service
    [Unit]
    Description=Node Exporter
    After=network.target

    [Service]
    User=ec2-user
    ExecStart=/usr/local/bin/node_exporter

    [Install]
    WantedBy=multi-user.target
    NODE_EOF

    systemctl enable node_exporter
    systemctl start node_exporter

    # 5. Install Promtail (Log shipping to Port 3100)
    curl -L https://github.com/grafana/loki/releases/download/v2.9.1/promtail-linux-amd64.zip -o promtail.zip
    unzip promtail.zip
    mv promtail-linux-amd64 /usr/local/bin/promtail

    cat <<PROM_EOF > /etc/promtail-config.yml
    server:
      http_listen_port: 9080
      grpc_listen_port: 0

    positions:
      filename: /tmp/positions.yaml

    clients:
      - url: http://10.0.0.20:3100/loki/api/v1/push

    scrape_configs:
    - job_name: flask-logs
      static_configs:
      - targets:
          - localhost
        labels:
          job: cloudpulse
          instance: ${var.project_name}-server
          __path__: /home/ec2-user/app/app.log
    PROM_EOF

    docker run -d --restart unless-stopped --name=node-exporter -p 9100:9100 prom/node-exporter

    cat <<P_SVC_EOF > /etc/systemd/system/promtail.service
    [Unit]
    Description=Promtail service
    After=network.target

    [Service]
    Type=simple
    User=root
    ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail-config.yml

    [Install]
    WantedBy=multi-user.target
    P_SVC_EOF

    systemctl enable promtail
    systemctl start promtail
  EOF

tags = {
  Name = "${var.project_name}-server"
}
}

# ============================================================
# PHASE 5: Observability (Security Group + Module)

resource "aws_instance" "observability" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "c7i-flex.large"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.cloudpulse_sg.id]
  private_ip             = "10.0.0.20"

  user_data_replace_on_change = true

  user_data = <<-EOF
#!/bin/bash
# Redirect all output to log file
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "--- Starting User Data Installation ---"

# 1. Install Docker & Compose Plugin
yum update -y
yum install -y docker
systemctl enable --now docker

# Install Docker Compose V2 Plugin manually
mkdir -p /usr/local/lib/docker/cli-plugins/
curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# 2. Create Directory Structure
mkdir -p /home/ec2-user/monitoring/prometheus
mkdir -p /home/ec2-user/monitoring/loki
mkdir -p /home/ec2-user/monitoring/grafana/provisioning/datasources
mkdir -p /home/ec2-user/monitoring/grafana/provisioning/dashboards
mkdir -p /home/ec2-user/monitoring/locust

# 3. Write Config Files (Ensuring NO indentation for the markers)

cat <<'COMPOSE_EOF' > /home/ec2-user/monitoring/docker-compose.yml
${file("${path.module}/monitoring/docker-compose.yml")}
COMPOSE_EOF

cat <<PROM_EOF > /home/ec2-user/monitoring/prometheus/prometheus.yml
${templatefile("${path.module}/monitoring/prometheus/prometheus.yml", {
  app_private_ip = "10.0.0.10"
})}
PROM_EOF

cat <<'LOKI_EOF' > /home/ec2-user/monitoring/loki/loki-config.yaml
${file("${path.module}/monitoring/loki/loki-config.yaml")}
LOKI_EOF

cat <<'DS_EOF' > /home/ec2-user/monitoring/grafana/provisioning/datasources/ds.yml
${file("${path.module}/monitoring/grafana/provisioning/datasources/ds.yml")}
DS_EOF

cat <<'LOCUST_EOF' > /home/ec2-user/monitoring/locust/locustfile.py
${file("${path.module}/monitoring/locust/locustfile.py")}
LOCUST_EOF

cat <<'DASH_PROV_EOF' > /home/ec2-user/monitoring/grafana/provisioning/dashboards/provider.yml
apiVersion: 1
providers:
  - name: 'Standard Dashboards'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /etc/grafana/provisioning/dashboards
DASH_PROV_EOF

cat <<'APP_EOF' > /home/ec2-user/monitoring/grafana/provisioning/dashboards/app.json
${file("${path.module}/monitoring/grafana/provisioning/dashboards/app.json")}
APP_EOF

# 4. Fix permissions and Start
echo "--- Fixing permissions and starting Docker Compose ---"
chown -R ec2-user:ec2-user /home/ec2-user/monitoring
cd /home/ec2-user/monitoring
docker compose up -d

echo "--- User Data Script Complete ---"
EOF

tags = { Name = "${var.project_name}-monitoring" }
}