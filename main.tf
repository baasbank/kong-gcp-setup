# *********************************************************************************************************************
# LAUNCH A LOAD BALANCER WITH A MANAGED INSTANCE GROUP BACKEND FOR KONG
# *********************************************************************************************************************


# ******************************************************************************
# FETCH MANUALLY CREATED KONG DB USER PASSWORD
# ******************************************************************************
data "google_secret_manager_secret_version" "kong-db-password" {
  secret = var.secret_name
}

# ******************************************************************************
# CREATE PRIVATE IP ADDRESS RANGE, PRIVATE SERVICE CONNECTION, AND NETWORK
# PEERING ROUTE
# ******************************************************************************

resource "google_compute_global_address" "kong_private_ip_address" {
  provider = google-beta

  name          = "baas-testing-private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.network.id
}

resource "google_service_networking_connection" "default" {
  network                 = google_compute_network.network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.kong_private_ip_address.name]
}

resource "google_compute_network_peering_routes_config" "peering_routes" {
  peering              = google_service_networking_connection.default.peering
  network              = google_compute_network.network.name
  import_custom_routes = true
  export_custom_routes = true
}

# ******************************************************************************
# CREATE A POSTGRES DATABASE INSTANCE WITH PRIVATE IP
# Also create
# - database
# - database user
# ******************************************************************************

resource "google_sql_database_instance" "kong" {
  name             = "kong"
  region           = "europe-west1"
  database_version = "POSTGRES_15"
  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled    = "false"
      private_network = google_compute_network.network.id
    }
  }

  deletion_protection = "false"
  depends_on          = [google_service_networking_connection.default]
}

resource "google_sql_database" "kong" {
  name     = "kong"
  instance = google_sql_database_instance.kong.name
}

resource "google_sql_user" "kong-user" {
  name     = "kong"
  instance = google_sql_database_instance.kong.name
  password = data.google_secret_manager_secret_version.kong-db-password.secret_data
}

# ******************************************************************************
# CREATE SERVICE ACCOUNT FOR KONG AND ASSIGN ROLE
# ******************************************************************************

resource "google_service_account" "kong" {
  account_id   = "kongregate"
  display_name = "kong"
}

resource "google_project_iam_member" "kong" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.kong.member
}

# ******************************************************************************
# CREATE THE LOAD BALANCER
# ******************************************************************************

module "kong_lb" {
  source                 = "./modules/loadbalancer"
  name                   = "kong"
  project                = var.project_id
  url_map                = google_compute_url_map.kong.self_link
  https_redirect_url_map = google_compute_url_map.kong_https_redirect.self_link
  ssl_certificates       = [google_compute_managed_ssl_certificate.kong.self_link]
}

# ******************************************************************************
# CREATE A GOOGLE MANAGED SSL CERTIFICATE
# ******************************************************************************

resource "google_compute_managed_ssl_certificate" "kong" {
  provider = google-beta
  project  = var.project_id
  name     = "certificate"

  lifecycle {
    create_before_destroy = true
  }

  managed {
    domains = var.managed_ssl_certificate_domains
  }
}

# ******************************************************************************
# CREATE INSTANCE TEMPLATES
# ******************************************************************************

resource "google_compute_instance_template" "kong_eu_west4" {
  name = "kong-eu-west4-template"
  disk {
    auto_delete  = true
    boot         = true
    device_name  = "persistent-disk-0"
    mode         = "READ_WRITE"
    source_image = "ubuntu-os-cloud/ubuntu-2004-lts"
    type         = "PERSISTENT"
  }
  machine_type = "n1-standard-1"
  metadata = {
    startup-script = <<-EOT
      #! /bin/bash
      sudo su root   
      curl -1sLf "https://packages.konghq.com/public/gateway-33/gpg.3B738D8FCD250236.key" |  gpg --dearmor | sudo tee /usr/share/keyrings/kong-gateway-33-archive-keyring.gpg > /dev/null
      curl -1sLf "https://packages.konghq.com/public/gateway-33/config.deb.txt?distro=ubuntu&codename=focal" | sudo tee /etc/apt/sources.list.d/kong-gateway-33.list > /dev/null
      sudo apt-get update
      sudo apt-get install -y kong-enterprise-edition=3.3.1.0
      sudo apt-mark hold kong-enterprise-edition
      apt install jq --yes
      CONFIG_FILE_PATH=/etc/kong/kong.conf
      cat << FOE | tee $CONFIG_FILE_PATH
      database = postgres
      pg_host = ${google_sql_database_instance.kong.ip_address.0.ip_address}
      pg_user = ${google_sql_user.kong-user.name}
      pg_password = ${data.google_secret_manager_secret_version.kong-db-password.secret_data}
      pg_database = ${google_sql_database.kong.name}
      proxy_listen = 0.0.0.0:8000 reuseport backlog=16384, 0.0.0.0:8443 http2 ssl reuseport backlog=16384
      admin_listen = 127.0.0.1:8001 reuseport backlog=16384, 127.0.0.1:8444 http2 ssl reuseport backlog=16384
      admin_gui_listen = 127.0.0.1:8002, 127.0.0.1:8445 ssl
      admin_gui_path = /manager
      admin_gui_url = http://localhost:8002/manager
      admin_api_uri = http://localhost:8001
      status_listen = 0.0.0.0:8100
      FOE
      sed -i 's/\"//g' $CONFIG_FILE_PATH
      NEEDS_BOOTSTRAP=$(kong migrations status | jq -r '.needs_bootstrap')
      if ($NEEDS_BOOTSTRAP == "true"); then kong migrations bootstrap; fi
      kong start
  EOT
  }
  network_interface {

    network    = google_compute_network.network.self_link
    subnetwork = google_compute_subnetwork.subnetwork02.self_link
  }
  region = "europe-west4"
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }
  service_account {
    email  = google_service_account.kong.email
    scopes = []
  }
  tags = ["allow-health-check", "kong"]
}

resource "google_compute_instance_template" "kong_eu_west1" {
  name = "kong-eu-west1-template"
  disk {
    auto_delete  = true
    boot         = true
    device_name  = "persistent-disk-0"
    mode         = "READ_WRITE"
    source_image = "ubuntu-os-cloud/ubuntu-2004-lts"
    type         = "PERSISTENT"
  }
  machine_type = "n1-standard-1"
  metadata = {
    startup-script = <<-EOT
      #! /bin/bash
      sudo su root   
      curl -1sLf "https://packages.konghq.com/public/gateway-33/gpg.3B738D8FCD250236.key" |  gpg --dearmor | sudo tee /usr/share/keyrings/kong-gateway-33-archive-keyring.gpg > /dev/null
      curl -1sLf "https://packages.konghq.com/public/gateway-33/config.deb.txt?distro=ubuntu&codename=focal" | sudo tee /etc/apt/sources.list.d/kong-gateway-33.list > /dev/null
      sudo apt-get update
      sudo apt-get install -y kong-enterprise-edition=3.3.1.0
      sudo apt-mark hold kong-enterprise-edition
      apt install jq --yes
      CONFIG_FILE_PATH=/etc/kong/kong.conf
      cat << FOE | tee $CONFIG_FILE_PATH
      database = postgres
      pg_host = ${google_sql_database_instance.kong.ip_address.0.ip_address}
      pg_user = ${google_sql_user.kong-user.name}
      pg_password = ${data.google_secret_manager_secret_version.kong-db-password.secret_data}
      pg_database = ${google_sql_database.kong.name}
      proxy_listen = 0.0.0.0:8000 reuseport backlog=16384, 0.0.0.0:8443 http2 ssl reuseport backlog=16384
      admin_listen = 127.0.0.1:8001 reuseport backlog=16384, 127.0.0.1:8444 http2 ssl reuseport backlog=16384
      admin_gui_listen = 127.0.0.1:8002, 127.0.0.1:8445 ssl
      admin_gui_path = /manager
      admin_gui_url = http://localhost:8002/manager
      admin_api_uri = http://localhost:8001
      status_listen = 0.0.0.0:8100
      FOE
      sed -i 's/\"//g' $CONFIG_FILE_PATH
      NEEDS_BOOTSTRAP=$(kong migrations status | jq -r '.needs_bootstrap')
      if ($NEEDS_BOOTSTRAP == "true"); then kong migrations bootstrap; fi
      kong start
  EOT
  }
  network_interface {

    network    = google_compute_network.network.self_link
    subnetwork = google_compute_subnetwork.subnetwork01.self_link
  }
  region = "europe-west1"
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }
  service_account {
    email  = google_service_account.kong.email
    scopes = []
  }
  tags = ["allow-health-check", "kong"]
}


# ******************************************************************************
# CREATE AUTOSCALERS
# ******************************************************************************

resource "google_compute_region_autoscaler" "kong_eu_west4_autoscaler" {
  name   = "kong-eu-west4-autoscaler"
  region = "europe-west4"
  target = google_compute_region_instance_group_manager.kong_eu_west4.id

  autoscaling_policy {
    max_replicas    = 4
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.7
    }
  }
}

resource "google_compute_region_autoscaler" "kong_eu_west1_autoscaler" {
  name   = "kong-eu-west1-autoscaler"
  region = "europe-west1"
  target = google_compute_region_instance_group_manager.kong_eu_west1.id

  autoscaling_policy {
    max_replicas    = 4
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.7
    }
  }
}

# ******************************************************************************
# CREATE INSTANCE GROUP MANAGERS
# ******************************************************************************

resource "google_compute_region_instance_group_manager" "kong_eu_west4" {
  name   = "kong-eu-west4-instance-group-manager"
  region = "europe-west4"
  named_port {
    name = "client"
    port = 8000
  }
  version {
    instance_template = google_compute_instance_template.kong_eu_west4.id
    name              = "primary"
  }
  base_instance_name = "vm"
  auto_healing_policies {
    health_check      = google_compute_health_check.kong-status.id
    initial_delay_sec = 300
  }
}

resource "google_compute_region_instance_group_manager" "kong_eu_west1" {
  name   = "kong-eu-west1-instance-group-manager"
  region = "europe-west1"
  named_port {
    name = "client"
    port = 8000
  }
  version {
    instance_template = google_compute_instance_template.kong_eu_west1.id
    name              = "primary"
  }
  base_instance_name = "vm"
  auto_healing_policies {
    health_check      = google_compute_health_check.kong-status.id
    initial_delay_sec = 300
  }
}

# ******************************************************************************
# CREATE FIREWALL RULES
# ******************************************************************************

resource "google_compute_firewall" "default" {
  name          = "kong-fw-allow-health-check"
  direction     = "INGRESS"
  network       = google_compute_network.network.self_link
  priority      = 1000
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["allow-health-check"]
  allow {
    ports    = ["8100"]
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "gcloud-ssh" {
  name          = "kong-allow-gcloud-ssh"
  direction     = "INGRESS"
  network       = google_compute_network.network.self_link
  priority      = 1010
  source_ranges = ["35.235.240.0/20"]
  allow {
    ports    = ["22"]
    protocol = "tcp"
  }
}
resource "google_compute_firewall" "allow-me-gcloud-ssh" {
  name          = "kong-allow-me-gcloud-ssh"
  direction     = "INGRESS"
  network       = google_compute_network.network.self_link
  priority      = 1010
  source_ranges = var.my_ip
  allow {
    ports    = ["22"]
    protocol = "tcp"
  }
}
resource "google_compute_firewall" "kong" {
  name          = "kong-fw-allow-all-http"
  direction     = "INGRESS"
  network       = google_compute_network.network.self_link
  priority      = 1011
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["kong"]

  allow {
    ports    = ["8000"]
    protocol = "tcp"
  }
}

# ******************************************************************************
# CREATE INSTANCE HEALTH CHECK
# ******************************************************************************

resource "google_compute_health_check" "kong-status" {
  name               = "kong-status-check"
  check_interval_sec = 5
  healthy_threshold  = 2
  http_health_check {
    port         = 8100
    request_path = "/status"
  }
  timeout_sec         = 5
  unhealthy_threshold = 2
}

# ******************************************************************************
# CREATE BACKEND SERVICE
# ******************************************************************************

resource "google_compute_backend_service" "kong-client" {
  name                            = "kong-client-backend-service"
  connection_draining_timeout_sec = 0
  health_checks                   = [google_compute_health_check.kong-status.id]
  load_balancing_scheme           = "EXTERNAL"
  port_name                       = "client"
  protocol                        = "HTTP"
  session_affinity                = "NONE"
  timeout_sec                     = 30
  backend {
    group           = google_compute_region_instance_group_manager.kong_eu_west4.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
  backend {
    group           = google_compute_region_instance_group_manager.kong_eu_west1.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ******************************************************************************
# CREATE URL MAPS
# ******************************************************************************

resource "google_compute_url_map" "kong" {
  name            = "kong-urlmap-http"
  default_service = google_compute_backend_service.kong-client.id

  host_rule {
    hosts        = var.managed_ssl_certificate_domains
    path_matcher = "matcher1"
  }

  path_matcher {
    name            = "matcher1"
    default_service = google_compute_backend_service.kong-client.id
    path_rule {
      paths   = ["/*"]
      service = google_compute_backend_service.kong-client.id
    }
  }
}

resource "google_compute_url_map" "kong_https_redirect" {
  project = var.project_id
  name    = "https-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_network" "network" {
  name                    = "baas-testing-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnetwork01" {
  name          = "subnetwork01"
  ip_cidr_range = "10.2.0.0/24"
  region        = "europe-west1"
  network       = google_compute_network.network.id
}

resource "google_compute_subnetwork" "subnetwork02" {
  name          = "subnetwork02"
  ip_cidr_range = "10.3.0.0/24"
  region        = "europe-west4"
  network       = google_compute_network.network.id
}

module "router" {
  for_each = var.routers

  source  = "terraform-google-modules/cloud-router/google"
  version = "~> 6.0"

  name    = "router"
  project = var.project_id
  region  = each.value.region
  network = google_compute_network.network.name
  nats = [
    {
      "name"                               = "${each.key}-nat",
      "source_subnetwork_ip_ranges_to_nat" = "LIST_OF_SUBNETWORKS"
      "subnetworks" = [
        for subnet in each.value.subnets :
        {
          "name"                    = each.value.subnets[0]
          "source_ip_ranges_to_nat" = ["PRIMARY_IP_RANGE"]
        }
      ]
    }
  ]
}
