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

variable "ami_id" {
  description = "The AMI ID for the VC hardened linux image"
  type        = string
  default     = "ami-05320f7bf2322b015" # Based on amazon linux image
}

# EC2 Instance with Embedded Cloud-Init Script
resource "aws_instance" "k3s_node" {
  ami           = var.ami_id
  instance_type = "t3.small"
  key_name      = "zl-veracode"            # Replace with your actual key name
  
  vpc_security_group_ids = ["sg-03f0dc27b74f3d481"] #replace with actual VPC

  #root device configuration:
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    delete_on_termination = true
    encrypted = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens = "required"
  }
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
                name: nginx-hardened
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
                    # POD-LEVEL SECURITY CONTEXT
                    securityContext:
                      runAsNonRoot: true
                      runAsUser: 101        # Default UID for nginx-unprivileged
                      runAsGroup: 101       # Default GID for nginx-unprivileged
                      fsGroup: 101          # Ensure mounted volumes are readable by this GID
                      seccompProfile:
                        type: RuntimeDefault

                    containers:
                      - name: nginx
                        image: nginxinc/nginx-unprivileged:stable-alpine
                        ports:
                          - containerPort: 8080
                      # CONTAINER-LEVEL SECURITY CONTEXT
                        securityContext:
                          allowPrivilegeEscalation: false
                          readOnlyRootFilesystem: true
                          capabilities:
                            drop: ["ALL"]   # Drop all Linux capabilities (ping, net_bind_service, etc.)

                        # REQUIRED FOR READ-ONLY FILESYSTEM
                        # NGINX must write to these locations to function:
                        volumeMounts:
                          - name: tmp-volume
                            mountPath: /tmp
                          - name: run-volume
                            mountPath: /var/run
                          - name: cache-volume
                            mountPath: /var/cache/nginx

                    # VOLUMES FOR THE WRITABLE PATHS
                    volumes:
                      - name: tmp-volume
                        emptyDir: {}
                      - name: run-volume
                        emptyDir: {}
                      - name: cache-volume
                        emptyDir: {}
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
                    targetPort: 8080
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
    Name = "terraform-k3s-hardened"
  }
}

output "instance_ip" {
  value = aws_instance.k3s_node.public_ip
}
