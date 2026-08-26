variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "project_number" {
  type        = string
  description = "GCP project number (obtenu via `gcloud projects describe $PROJECT_ID --format='value(projectNumber)'`)"
}

variable "billing_account_id" {
  type        = string
  description = "Billing account ID (compte académique UY1)"
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "zone" {
  type    = string
  default = "europe-west1-b"
}

variable "alert_email" {
  type    = string
  default = "stive.chameni@facsciences-uy1.cm"
}

variable "budget_amount_usd" {
  type    = number
  default = 300
}

variable "budget_thresholds" {
  type    = list(number)
  default = [50, 80, 95, 100]
}
