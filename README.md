This is a quick project designed to deploy a K3s single-node cluster inside an EC2 instance using Terraform

Usage: 
Git Clone ... 
cd directory
Modify the `example.tf` file to fill in any account/org specific AWS objects
    - AMI ID (Default is us-east-1 Ubuntu 24.04)
    - Desired SSH Keys
    - VPC allocations
terraform init
terraform apply 

The final result should be an EC2 instance that you can SSH into and copy in your VRM runtime agent Helm commands to

Requirements: 
- AWS CLI to be installed and authenticated
- Terraform to be installed 

Additional Yaml files are the expected Nginx application deployment and can be used for repo or directory scanning with the Veracode IAC scanner