variable "project" {
  type        = string
  description = "Enter the name of the project to house the compute"
}

variable "region" {
  type       = string
  default    = "us-central1"
  description = "The region to deploy the SQL instance to"
}

variable "destroy_all" {
  type      = bool
  default   = true
  description = "Should we destroy everything?"
}


######
## Providers
######

provider "google" {
  project = var.project
  region  = var.region
}

provider "google-beta" {
  project = var.project
  region  = var.region
}

######
## Networking
######

resource "google_compute_network" "private_network" {
  provider = google-beta

  name = "private-network"
}

resource "google_compute_global_address" "private_ip_address" {
  provider = google-beta

  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.private_network.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  provider = google-beta

  network                 = google_compute_network.private_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}



######
## CloudSQL DB
######

locals {
  authorized_networks = {
    "datastream-whitelist-1" = "34.67.6.0/24"
    "datastream-whitelist-2" = "34.67.234.0/24"
    "datastream-whitelist-3" = "34.72.28.0/24"
    "datastream-whitelist-4" = "34.72.239.0/24"
    "datastream-whitelist-5" = "34.71.242.0/24"
  }
}


resource "google_sql_database_instance" "master" {
  database_version = "MYSQL_5_7"
  region           = var.region
  # require_ssl      = true

  deletion_protection = false

  settings {

    tier = "db-f1-micro"
    disk_autoresize   = true
    ip_configuration {
      private_network = google_compute_network.private_network.id

      dynamic authorized_networks {
        for_each = local.authorized_networks
        iterator = net

        content {
          name  = net.key
          value = net.value
        }
      }

    }
    backup_configuration {
      enabled            = true
      binary_log_enabled = true
    }

  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}



resource "google_sql_ssl_cert" "client_cert" {
  common_name = "cdc-client"
  instance    = google_sql_database_instance.master.name
}



resource "google_sql_database" "menagerie" {
  name      = "menagerie"
  instance  = "${google_sql_database_instance.master.name}"
}


resource "random_password" "animal_user_passwd" {
  length           = 16
  special          = true
  override_special = "_%@"
}



resource "google_sql_user" "user" {
  name     = "animal"
  instance = google_sql_database_instance.master.name
  password = random_password.animal_user_passwd.result
}


resource "random_uuid" "bucket_suffix" {
}

######
## Storage
######

resource "google_storage_bucket" "target-bucket" {
  name          = "menagerie-${random_uuid.bucket_suffix.result}"
  location      = "US-CENTRAL1"
  force_destroy = true

}


######
## BigQuery
######

resource "google_bigquery_dataset" "menagerie-reporting" {
  dataset_id                  = "menagerie_reporting"
  friendly_name               = "menagerie_reporting"
  description                 = "Reporting data from the CloudSQL menagerie DB"
  
  delete_contents_on_destroy  = var.destroy_all

}

resource "google_bigquery_table" "events" {
  dataset_id = google_bigquery_dataset.menagerie-reporting.dataset_id
  table_id   = "events"
  deletion_protection = false

  schema = file("${path.module}/events.schema.json")
}




resource "google_bigquery_table" "pets" {
  dataset_id = google_bigquery_dataset.menagerie-reporting.dataset_id
  table_id   = "pets"
  deletion_protection = false

  schema = file("${path.module}/pets.schema.json")

}


