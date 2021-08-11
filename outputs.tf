
output "master_sql_name" {
    value       = google_sql_database_instance.master.name
    description = "The name of the CloudSQL instance. Useful for connecting."
}

output "animal_user_passwd" {
    value       = google_sql_user.user.password
    sensitive   = true
    description = "The password for the animal user"
}

output "target_bucket" {
    value       = google_storage_bucket.target-bucket.name
    description = "The computed value of the name of the bucket"
}

output "region" {
    value       = var.region
    description = "The region the CloudSQL instance is in"
}

