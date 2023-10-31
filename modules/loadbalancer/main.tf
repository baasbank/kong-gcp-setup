# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DEPLOY A HTTP LOAD BALANCER
# This module deploys a HTTP(S) Cloud Load Balancer
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


# ------------------------------------------------------------------------------
# CREATE A PUBLIC IP ADDRESS
# ------------------------------------------------------------------------------

resource "google_compute_global_address" "default" {
  project      = var.project
  name         = "${var.name}-address"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"
}

# ------------------------------------------------------------------------------
# CREATE HTTP FORWARDING RULE AND PROXY
# ------------------------------------------------------------------------------

resource "google_compute_target_http_proxy" "http" {
  project = var.project
  name    = "${var.name}-http-proxy"
  url_map = var.https_redirect_url_map
}

resource "google_compute_global_forwarding_rule" "http" {
  provider   = google-beta
  project    = var.project
  name       = "${var.name}-http-rule"
  target     = google_compute_target_http_proxy.http.self_link
  ip_address = google_compute_global_address.default.address
  port_range = "80"

  depends_on = [google_compute_global_address.default]
}

# ------------------------------------------------------------------------------
# CREATE HTTPS FORWARDING RULE AND PROXY
# ------------------------------------------------------------------------------

resource "google_compute_global_forwarding_rule" "https" {
  provider   = google-beta
  project    = var.project
  name       = "${var.name}-https-rule"
  target     = google_compute_target_https_proxy.https.self_link
  ip_address = google_compute_global_address.default.address
  port_range = "443"

  depends_on = [google_compute_global_address.default]
}

resource "google_compute_target_https_proxy" "https" {
  project          = var.project
  name             = "${var.name}-https-proxy"
  url_map          = var.url_map
  ssl_certificates = var.ssl_certificates
}

# ------------------------------------------------------------------------------
# CREATE A RECORD POINTING TO THE PUBLIC IP OF THE LOAD BALANCER
# ------------------------------------------------------------------------------

resource "google_dns_record_set" "dns" {
  project      = var.project
  name         = "baas.test.caas.selling.ingka.com."
  type         = "A"
  ttl          = 60
  managed_zone = "test"
  rrdatas      = [google_compute_global_address.default.address]
}