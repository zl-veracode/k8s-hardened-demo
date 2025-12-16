terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.0"    
    }
  }
}

provider "aws" {
  # Configuration options
  region = "us-east-1" 
}


# EC2 Instance with Embedded Cloud-Init Script
resource "aws_instance" "k3s_node" {
  ami           = "ami-0ecb62995f68bb549" # Base us-east-1 x86 Ubuntu 24.04 -- to be updated with hardened image
  instance_type = "t3.small"
  key_name      = "zl-veracode"            # Replace with your actual key name
  
  vpc_security_group_ids = ["sg-03f0dc27b74f3d481"] #replace with actual VPC

  # Cloudinit script to configure the K3s and Nginx deployment

  user_data = <<-EOF
              #!/bin/bash
              # Update system
              apt-get update -y
              apt-get upgrade -y
              apt-get install -y apt-transport-https gpg

              # Install K3s (Single node cluster)
              curl -sfL https://get.k3s.io | sh -
              
              #Install helm (For the helm-cli to be used for runtime agent install) 
              curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
              echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
              apt-get update
              apt-get install helm
              
              # Wait for k3s to be ready and modify kubeconfig permissions
              # so the default user can read it (optional, for convenience)
              until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 2; done
              chmod 644 /etc/rancher/k3s/k3s.yaml

              #Create the KUBECONFIG environment Variable to point to point to the k3s config that was just created
              echo 'KUBECONFIG="/etc/rancher/k3s/k3s.yaml"' >> /etc/environment

              # Writing a quick nginx Manifest to start a pod for POC Purposes 
              # Will update this to pull a public manifest in the future
              
              MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
              until [ -d "$MANIFEST_DIR" ]; do sleep 5; done
              
              cat <<EOT >> $MANIFEST_DIR/nginx-test.yaml
              apiVersion: apps/v1
              kind: Deployment
              metadata:
                name: nginx-deployment
              spec:
                replicas: 1
                selector:
                  matchLabels:
                    app: nginx
                template:
                  metadata:
                    labels:
                      app: nginx
                  spec:
                    containers:
                    - name: nginx
                      image: nginx:latest
                      ports:
                      - containerPort: 80
              ---
              apiVersion: v1
              kind: Service
              metadata:
                name: nginx-service
              spec:
                selector:
                  app: nginx
                ports:
                  - port: 80
                    targetPort: 80
              ---
              apiVersion: networking.k8s.io/v1
              kind: Ingress
              metadata:
                name: nginx-ingress
                annotations:
                  # Optional: Disables SSL requirement for testing
                  traefik.ingress.kubernetes.io/router.entrypoints: web
              spec:
                rules:
                - http:
                    paths:
                    - path: /
                      pathType: Prefix
                      backend:
                        service:
                          name: nginx-service
                          port:
                            number: 80
              EOT
              EOF
  # ----------------------------

  tags = {
    Name = "terraform-k3s-demo"
  }
}

output "instance_ip" {
  value = aws_instance.k3s_node.public_ip
}
