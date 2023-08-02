# Define a Terraform variable for the project tag
variable "project_tag" {
  type    = string
  default = "kubernetes"
}

# Specify the AWS provider and region
provider "aws" {
  region = "us-west-2"
}

# Find the most recent Ubuntu 20.04 LTS AMI in us-west-2
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical account ID for official Ubuntu AMIs
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Create the AWS VPC for the Kubernetes cluster
resource "aws_vpc" "kubernetes_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name    = "kubernetes-vpc"
    project = var.project_tag
  }
}

# Create the AWS subnet for the Kubernetes cluster
resource "aws_subnet" "kubernetes_subnet" {
  vpc_id            = aws_vpc.kubernetes_vpc.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-west-2a"

  tags = {
    Name    = "kubernetes-subnet"
    project = var.project_tag
  }
}

# Create the AWS security group for the Kubernetes cluster
resource "aws_security_group" "kubernetes_sg" {
  vpc_id = aws_vpc.kubernetes_vpc.id

  # Ingress rules to allow SSH and Kubernetes API traffic
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress rule to allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "kubernetes-sg"
    project = var.project_tag
  }
}

# Create the AWS Internet Gateway
resource "aws_internet_gateway" "kubernetes_igw" {
  vpc_id = aws_vpc.kubernetes_vpc.id

  tags = {
    Name    = "kubernetes-igw"
    project = var.project_tag
  }
}

# Update the main route table of the public subnet to route traffic through the Internet Gateway
resource "aws_route" "public_subnet_route" {
  route_table_id         = aws_vpc.kubernetes_vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.kubernetes_igw.id
}

# Create the AWS instances for the Kubernetes control plane
resource "aws_instance" "kubernetes_control_plane" {
  count         = 1
  ami           = data.aws_ami.ubuntu.id  # Use the latest Ubuntu 20.04 LTS AMI
  instance_type = "t3.medium"
  key_name      = "kube-key"
  subnet_id     = aws_subnet.kubernetes_subnet.id
  vpc_security_group_ids = [aws_security_group.kubernetes_sg.id]
  associate_public_ip_address = true  # Allocate public IP address to the instance

  tags = {
    Name    = "kubernetes-control-plane"
    project = var.project_tag
  }
}

# Create the AWS instances for the Kubernetes worker nodes
resource "aws_instance" "kubernetes_worker" {
  count         = 2
  ami           = data.aws_ami.ubuntu.id  # Use the latest Ubuntu 20.04 LTS AMI
  instance_type = "t3.medium"
  key_name      = "kube-key"
  subnet_id     = aws_subnet.kubernetes_subnet.id
  vpc_security_group_ids = [aws_security_group.kubernetes_sg.id]
  associate_public_ip_address = true  # Allocate public IP address to the instance

  tags = {
    Name    = "kubernetes-worker-${count.index + 1}"
    project = var.project_tag
  }
}

# Use a null_resource to generate the Ansible inventory file after Terraform creates the instances
resource "null_resource" "generate_ansible_inventory" {
  # Use the local-exec provisioner to execute the shell command to generate the Ansible inventory file
  provisioner "local-exec" {
    command = <<-EOT
      echo "[control_plane]" > inventory.ini
      echo "${join("\n", aws_instance.kubernetes_control_plane.*.public_ip)}" >> inventory.ini
      echo "" >> inventory.ini
      echo "[worker]" >> inventory.ini
      echo "${join("\n", aws_instance.kubernetes_worker.*.public_ip)}" >> inventory.ini
    EOT
  }
}

# Create the local_file data source to read the inventory file
data "local_file" "inventory" {
  filename = "./inventory.ini"

  # Add depends_on to ensure the inventory file is generated before running Ansible
  depends_on = [null_resource.generate_ansible_inventory]
}

# Use the local_file data source as the content for the Ansible playbook
resource "null_resource" "run_ansible" {
  count = length(aws_instance.kubernetes_control_plane)

  # Use triggers to get the public IP from the control_plane instances
  triggers = {
    public_ip = aws_instance.kubernetes_control_plane[count.index].public_ip
  }

  # Use Terraform's local-exec provisioner to run Ansible playbook
  provisioner "local-exec" {
    command = <<-EOT
      # Wait for SSH port to become available
      until nc -z -v ${self.triggers.public_ip} 22; do sleep 5; done

      # Run the Ansible playbook on the local machine, specifying the inventory file
      ansible-playbook -i ${data.local_file.inventory.filename} -u ubuntu --private-key "~/.ssh/kube-key.pem" ansible/playbook.yml
    EOT
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = "~/.ssh/kube-key.pem"
    host        = self.triggers.public_ip
  }
}


