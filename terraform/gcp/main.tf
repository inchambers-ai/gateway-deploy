// inchambers-gateway — GCP Cloud Run deployment.
//
// Provisions:
//   * VPC with serverless VPC Access connector
//   * Artifact Registry repo (gateway images)
//   * Cloud SQL Postgres (db-f1-micro)
//   (No Memorystore — relay rate-limits in-memory at default scale)
//   * Secret Manager entries (gateway master, LiteLLM master, OpenRouter, PG password)
//   * Cloud Run services: relay, litellm, admin-ui, caddy (public)
//   * Dedicated runtime service account with access to secrets + Cloud SQL

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.39" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}
variable "name" { type = string }
variable "org_id" { type = string }
variable "gateway_master_key" {
  type      = string
  sensitive = true
}
variable "litellm_master_key" {
  type      = string
  sensitive = true
  default   = ""
}
variable "openrouter_api_key" {
  type      = string
  sensitive = true
  default   = ""
}
variable "pg_admin_password" {
  type      = string
  sensitive = true
}
variable "domain_name" {
  type    = string
  default = ""
}
variable "allowed_origin" {
  type    = string
  default = "https://app.inchambers.ai"
}
# Protect the Cloud SQL instance (credential store) from accidental/malicious
# `terraform destroy`. Default false keeps dev teardown easy; set true for prod.
variable "enable_deletion_protection" {
  type    = bool
  default = false
}
variable "jwks_url" {
  type    = string
  default = "https://app.inchambers.ai/.well-known/jwks.json"
}
variable "image_tag" {
  type    = string
  default = "latest"
}

locals {
  litellm_key = coalesce(var.litellm_master_key, "sk-${random_id.litellm.hex}")
  image_repo  = "${var.region}-docker.pkg.dev/${var.project_id}/${var.name}"
}

resource "random_id" "litellm" { byte_length = 24 }

// ── Enable APIs ──────────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "vpcaccess.googleapis.com",
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

// ── Artifact Registry ────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "repo" {
  repository_id = var.name
  format        = "DOCKER"
  location      = var.region
  description   = "inchambers-gateway images for ${var.name}"
  depends_on    = [google_project_service.apis]
}

// ── Secret Manager ───────────────────────────────────────────────────────
resource "google_secret_manager_secret" "gateway_master" {
  secret_id  = "${var.name}-gateway-master-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}
resource "google_secret_manager_secret_version" "gateway_master" {
  secret      = google_secret_manager_secret.gateway_master.id
  secret_data = var.gateway_master_key
}

resource "google_secret_manager_secret" "litellm_master" {
  secret_id = "${var.name}-litellm-master-key"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "litellm_master" {
  secret      = google_secret_manager_secret.litellm_master.id
  secret_data = local.litellm_key
}

resource "google_secret_manager_secret" "pg_password" {
  secret_id = "${var.name}-pg-password"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "pg_password" {
  secret      = google_secret_manager_secret.pg_password.id
  secret_data = var.pg_admin_password
}

resource "google_secret_manager_secret" "openrouter" {
  count     = var.openrouter_api_key == "" ? 0 : 1
  secret_id = "${var.name}-openrouter-api-key"
  replication {
    auto {}
  }
}
resource "google_secret_manager_secret_version" "openrouter" {
  count       = var.openrouter_api_key == "" ? 0 : 1
  secret      = google_secret_manager_secret.openrouter[0].id
  secret_data = var.openrouter_api_key
}

// ── Runtime SA ───────────────────────────────────────────────────────────
resource "google_service_account" "runtime" {
  account_id   = "${var.name}-runtime"
  display_name = "inchambers-gateway runtime (${var.name})"
}

resource "google_secret_manager_secret_iam_member" "access" {
  for_each = merge(
    { gateway = google_secret_manager_secret.gateway_master.id,
      litellm = google_secret_manager_secret.litellm_master.id,
      pg      = google_secret_manager_secret.pg_password.id },
    var.openrouter_api_key == "" ? {} : { openrouter = google_secret_manager_secret.openrouter[0].id }
  )
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

// ── VPC + connector ──────────────────────────────────────────────────────
resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.50.0.0/20"
  private_ip_google_access = true
}
resource "google_vpc_access_connector" "conn" {
  name          = "${var.name}-conn"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.50.240.0/28"
  depends_on    = [google_project_service.apis]
}

// ── Private Services Access (for the Cloud SQL private IP) ────────────────
// Reserves a range and peers the VPC with servicenetworking so Cloud SQL can
// receive a private IP reachable from Cloud Run via the connector. This is
// what lets us drop the DB's public IP.
resource "google_compute_global_address" "sql_psa" {
  name          = "${var.name}-sql-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}
resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_psa.name]
  depends_on              = [google_project_service.apis]
}

// ── Cloud SQL ────────────────────────────────────────────────────────────
resource "google_sql_database_instance" "pg" {
  name             = "${var.name}-pg"
  database_version = "POSTGRES_16"
  region           = var.region
  depends_on       = [google_project_service.apis, google_service_networking_connection.psa]

  settings {
    tier    = "db-f1-micro"
    edition = "ENTERPRISE"
    ip_configuration {
      // Private IP only — no public surface. Reached from Cloud Run over the
      // VPC connector (ALL_TRAFFIC egress). Requires the PSA peering above.
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
    backup_configuration {
      enabled = true
      start_time = "03:00"
      // For production also enable point_in_time_recovery_enabled = true.
    }
  }
  // Default false keeps `terraform destroy` easy for dev; set the variable true
  // for production so the credential store can't be wiped accidentally.
  deletion_protection = var.enable_deletion_protection
}

resource "google_sql_user" "gateway" {
  name     = "gateway"
  instance = google_sql_database_instance.pg.name
  password = var.pg_admin_password
}

resource "google_sql_database" "db" {
  name     = "gateway"
  instance = google_sql_database_instance.pg.name
}

// Memorystore removed — the relay rate-limits in-memory, LiteLLM runs
// single-instance. Add `google_redis_instance` back and thread REDIS_URL
// if you scale either service past one replica.

// ── Cloud Run services ───────────────────────────────────────────────────
locals {
  db_url = "postgres://gateway:${urlencode(var.pg_admin_password)}@${google_sql_database_instance.pg.private_ip_address}:5432/gateway?sslmode=require"

  common_env = [
    { name = "GATEWAY_ORG_ID", value = var.org_id },
    { name = "JWKS_URL", value = var.jwks_url },
    { name = "DATABASE_URL", value = local.db_url },
  ]
}

resource "google_cloud_run_v2_service" "relay" {
  name     = "${var.name}-relay"
  location = var.region
  # Internal-only: reachable just from the VPC (i.e. via Caddy's connector),
  # not from the public internet. Combined with allUsers invoker below, this is
  # the network control that closes direct *.run.app access without needing
  # Caddy to mint per-request ID tokens.
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    timeout               = "3600s"
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    service_account = google_service_account.runtime.email
    vpc_access {
      connector = google_vpc_access_connector.conn.id
      egress    = "ALL_TRAFFIC"
    }
    containers {
      image = "${local.image_repo}/ic-gateway-relay:${var.image_tag}"
      ports { container_port = 8081 }
      resources {
        limits = { cpu = "1000m", memory = "1Gi" }
      }
      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }
      env {
        name  = "RELAY_BIND_ADDR"
        value = "0.0.0.0:8081"
      }
      env {
        name = "GATEWAY_MASTER_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.gateway_master.secret_id
            version = "latest"
          }
        }
      }
    }
    scaling {
      min_instance_count = 1
      max_instance_count = 5
    }
  }
  depends_on = [google_secret_manager_secret_iam_member.access]
}

resource "google_cloud_run_v2_service" "litellm" {
  name     = "${var.name}-litellm"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    timeout               = "3600s"
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    service_account = google_service_account.runtime.email
    vpc_access {
      connector = google_vpc_access_connector.conn.id
      egress    = "ALL_TRAFFIC"
    }
    containers {
      image = "${local.image_repo}/ic-gateway-litellm:${var.image_tag}"
      ports { container_port = 4000 }
      resources {
        limits = { cpu = "1000m", memory = "1Gi" }
      }
      dynamic "env" {
        for_each = local.common_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }
      env {
        name = "LITELLM_MASTER_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.litellm_master.secret_id
            version = "latest"
          }
        }
      }
      dynamic "env" {
        for_each = var.openrouter_api_key == "" ? [] : [1]
        content {
          name = "OPENROUTER_API_KEY"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.openrouter[0].secret_id
              version = "latest"
            }
          }
        }
      }
    }
    scaling {
      min_instance_count = 1
      max_instance_count = 5
    }
  }
  depends_on = [google_secret_manager_secret_iam_member.access]
}

resource "google_cloud_run_v2_service" "admin_ui" {
  name     = "${var.name}-admin"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    timeout               = "3600s"
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    service_account = google_service_account.runtime.email
    containers {
      image = "${local.image_repo}/ic-gateway-admin-ui:${var.image_tag}"
      ports { container_port = 3000 }
      resources {
        limits = { cpu = "500m", memory = "512Mi" }
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }
  }
}

// The Caddy service is public — it fronts everything.
resource "google_cloud_run_v2_service" "caddy" {
  name     = "${var.name}-caddy"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    timeout               = "3600s"
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    service_account = google_service_account.runtime.email
    vpc_access {
      connector = google_vpc_access_connector.conn.id
      egress    = "ALL_TRAFFIC"
    }
    containers {
      image = "${local.image_repo}/ic-gateway-caddy:${var.image_tag}"
      ports { container_port = 80 }
      resources {
        limits = { cpu = "500m", memory = "512Mi" }
      }
      env {
        name  = "GATEWAY_DOMAIN"
        value = var.domain_name == "" ? ":80" : var.domain_name
      }
      env {
        name  = "CADDY_TLS_MODE"
        value = "off" // Cloud Run terminates TLS for us.
      }
      env {
        name  = "ALLOWED_ORIGIN"
        value = var.allowed_origin
      }
      # Cloud Run assigns per-service URLs dynamically. Strip the scheme
      # and set the Caddyfile upstreams to the bare host:443 — Caddy
      # reverse_proxy with https:// upstream handles TLS to internal
      # services too.
      env {
        name  = "UPSTREAM_RELAY"
        value = "https://${replace(google_cloud_run_v2_service.relay.uri, "https://", "")}"
      }
      env {
        name  = "UPSTREAM_LITELLM"
        value = "https://${replace(google_cloud_run_v2_service.litellm.uri, "https://", "")}"
      }
      env {
        name  = "UPSTREAM_ADMIN"
        value = "https://${replace(google_cloud_run_v2_service.admin_ui.uri, "https://", "")}"
      }
    }
    scaling {
      min_instance_count = 1
      max_instance_count = 3
    }
  }
  depends_on = [
    google_cloud_run_v2_service.relay,
    google_cloud_run_v2_service.litellm,
    google_cloud_run_v2_service.admin_ui,
  ]
}

// Allow unauthenticated invocation of the public Caddy service.
resource "google_cloud_run_v2_service_iam_member" "caddy_public" {
  name     = google_cloud_run_v2_service.caddy.name
  location = google_cloud_run_v2_service.caddy.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

// allUsers invoker is retained ON PURPOSE: the backends are now set to
// INGRESS_TRAFFIC_INTERNAL_ONLY (above), so they are only reachable from the
// VPC (i.e. via Caddy's connector), never from the public internet. Cloud Run
// checks BOTH network ingress AND IAM; keeping allUsers means Caddy's
// internal, unauthenticated requests pass the IAM check without Caddy having
// to mint per-request Google ID tokens. The internet can't reach these URLs
// at all, so allUsers here is not a public exposure.
//
// VERIFY ON A LIVE GCP PROJECT: confirm Caddy (connector, ALL_TRAFFIC egress)
// can still reach the internal backends after this change. If a deploy can't
// reach them, the rollback is to set these three services back to
// ingress = "INGRESS_TRAFFIC_ALL".
resource "google_cloud_run_v2_service_iam_member" "internal" {
  for_each = toset([
    google_cloud_run_v2_service.relay.name,
    google_cloud_run_v2_service.litellm.name,
    google_cloud_run_v2_service.admin_ui.name,
  ])
  name     = each.key
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "gateway_url" {
  value = google_cloud_run_v2_service.caddy.uri
}
output "artifact_registry_url" {
  value = local.image_repo
}
