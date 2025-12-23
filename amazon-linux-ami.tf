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
  profile = "Engineer2-221433242586"
}


# EC2 Instance with Embedded Cloud-Init Script
resource "aws_instance" "k3s_node" {
  ami           = "ami-0a11d8be7d69b2658" # us-east-1 hardened image - based on AWS Linux
  instance_type = "t3.small"
  key_name      = "zl-veracode"            # Replace with your actual key name
  subnet_id     = "subnet-a0756988"
  vpc_security_group_ids = ["sg-eeb4998b","sg-024c9979b7d507b06"] #replace with actual SG IDs

  #root device configuration:
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
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
              yum update -y
              yum upgrade -y

              yum install git -y

              # Install K3s (Single node cluster)
              curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true sh -
              
              #Install helm (For the helm-cli to be used for runtime agent install) 
              curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
              chmod 700 get_helm.sh
              ./get_helm.sh

              # Wait for k3s to be ready and modify kubeconfig permissions
              # so the default user can read it (optional, for convenience)
              until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 2; done
              chmod 644 /etc/rancher/k3s/k3s.yaml

              #Update the firewall rules to allow for traffic originating from the default pod CIDR
              #K3s defaults to 10.42.0.0/16 for pod network and 10.43.0.0/16 for services - please revise the firewall updates if you modify those values in the deployment
              firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
              firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
              firewall-cmd --reload


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
