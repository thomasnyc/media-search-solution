// Copyright 2024 Google, LLC
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     https://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

terraform {
  required_version = ">= 0.12"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.5.0"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.5.0"
    }
  }

  provider_meta "google" {
    module_name = "cloud-solutions/media-search-solution-deploy-v1.0.0"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "default" {
}

locals {
  solution_prefix = "media-search"
}

module "project_services" {
  source                      = "github.com/terraform-google-modules/terraform-google-project-factory.git//modules/project_services?ref=97a03f2bf4bf1972e12467bc90850e53b6730d8f" # commit hash of version 18.0.0
  project_id                  = var.project_id
  disable_services_on_destroy = false
  disable_dependent_services  = false
  activate_apis = [
    "iam.googleapis.com",
    "pubsub.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iap.googleapis.com",
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_artifact_registry_repository" "docker-repo" {
  format        = "DOCKER"
  location      = var.region
  repository_id = "${local.solution_prefix}-repo"
  description   = "Docker containers"
  depends_on    = [module.project_services.project_id]
}

module "low_res_resources" {
  source         = "./modules/low_res"
  region         = var.region
  low_res_bucket = var.low_res_bucket
  depends_on     = [module.project_services.project_id]
}

module "high_res_resources" {
  source          = "./modules/high_res"
  region          = var.region
  high_res_bucket = var.high_res_bucket
  depends_on      = [module.project_services.project_id]
}

module "bigquery" {
  source = "./modules/bigquery"
  region = var.region
}

resource "local_file" "deployment_configuration" {
  filename = "${path.root}/../../configs/.env.local.toml"

  content = templatefile("${path.module}/../../configs/example_.env.local.toml", {
    project_id            = var.project_id
    high_res_input_bucket = var.high_res_bucket
    low_res_output_bucket = var.low_res_bucket
  })
}

module "cloud_build_account" {
  source     = "github.com/terraform-google-modules/terraform-google-service-accounts?ref=a11d4127eab9b51ec9c9afdaf51b902cd2c240d9" #commit hash of version 4.0.0
  names      = ["cloud-build"]
  project_id = module.project_services.project_id
  project_roles = [
    "${var.project_id}=>roles/logging.logWriter",
    "${var.project_id}=>roles/storage.admin",
    "${var.project_id}=>roles/artifactregistry.writer",
    "${var.project_id}=>roles/run.developer",
  ]
  display_name = "Cloud Build Service Account"
  description  = "specific custom service account for Cloud Build"
}

module "gcloud_build_app" {
  source = "github.com/terraform-google-modules/terraform-google-gcloud?ref=db25ab9c0e9f2034e45b0034f8edb473dde3e4ff" # commit hash of version 3.5.0

  create_cmd_entrypoint = "gcloud"
  create_cmd_body       = <<-EOT
    builds submit "${path.module}/../.." \
      --project ${module.project_services.project_id} \
      --region ${var.region} \
      --default-buckets-behavior regional-user-owned-bucket \
      --tag "${var.region}-docker.pkg.dev/${module.project_services.project_id}/${google_artifact_registry_repository.docker-repo.name}/${local.solution_prefix}" \
      --service-account "projects/${module.project_services.project_id}/serviceAccounts/${module.cloud_build_account.email}"
  EOT
  enabled               = true
}

module "media_search_service_account" {
  source     = "github.com/terraform-google-modules/terraform-google-service-accounts?ref=a11d4127eab9b51ec9c9afdaf51b902cd2c240d9" #commit hash of version 4.0.0
  project_id = var.project_id
  names      = ["media-search-sa"]
  project_roles = [
    "${var.project_id}=>roles/storage.objectAdmin",
    "${var.project_id}=>roles/bigquery.user",
    "${var.project_id}=>roles/bigquery.dataEditor",
    "${var.project_id}=>roles/aiplatform.user",
    "${var.project_id}=>roles/pubsub.subscriber",
    "${var.project_id}=>roles/cloudtrace.agent",
    "${var.project_id}=>roles/monitoring.metricWriter",
  ]
  display_name = "Media Search Web Service Account"
  description  = "specific custom service account for Web APP"
}

resource "google_project_service_identity" "vertex_ai_service_agent" {
  provider = google-beta
  project  = var.project_id
  service  = "aiplatform.googleapis.com"
}

resource "google_project_iam_member" "vertex_ai_service_agent_roles" {
  project = var.project_id
  member  = "serviceAccount:service-${data.google_project.default.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
  depends_on = [
    google_project_service_identity.vertex_ai_service_agent
  ]
  for_each = toset([
    "roles/aiplatform.serviceAgent",
    "roles/storage.objectAdmin",
    "roles/bigquery.dataViewer",
    "roles/bigquery.jobUser",
    "roles/pubsub.admin",
  ])
  role = each.key
}
