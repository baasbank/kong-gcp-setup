# Set up Kong Gateway on GCP

## Stateful Kong Gateway cluster with CloudSQL postgres DB, Google Cloud VM instances, and HTTPS load balancer
This repo contains terraform scripts for setting up a stateful Kong Gateway cluster on GCP. 

### INFRASTRUCTURE
The infrastructure is shown in the diagram below

<img width="1181" alt="infrastructure diagram" src="https://github.com/baasbank/kong-gcp-setup/assets/26189554/2833761d-eafe-46f6-8de1-686b51f36735">

- HTTPS load balancer with SSL certificate, of course.
- Firewall rules for security; expatiated on in the security considerations section.
- A http-to-https redirect URL map that does exactly that to ensure only secure connections to the load balancer.
- A VPC network with 2 instance groups in 2 regions for high availability.
- A cloud SQL postgres database with only a private connection.


### PREREQUISITES
- An already created DNS zone.
- An already created storage bucket to store the terraform state file.
- A secret in Google Secret Manager for the Kong DB password

### HOW TO RUN
1. Clone this repository.
2. Create a storage bucket in your GCP project to store your terraform state file.
3. Use the name of the bucket created above in `provider.tf`.
4. Update the default values of the variables in `variables.tf` to match yours.