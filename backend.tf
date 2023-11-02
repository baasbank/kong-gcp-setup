terraform {
  backend "gcs" {
    bucket = "baas-testing-the-mic"
  }
  required_version = "~> 1.6.2"
}
