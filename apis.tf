

# Not sure if this is needed
module "project-services" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"

  project_id  = var.project
  disable_services_on_destroy = false
  activate_apis = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "sqladmin.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com"
  ]
}