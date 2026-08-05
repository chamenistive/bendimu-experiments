variable "project_id" { type = string }
variable "project_number" { type = string }
variable "billing_account_id" { type = string }
variable "alert_email" { type = string }
variable "display_name" {
  type    = string
  default = "Bendimu Monthly Budget"
}
variable "budget_amount_usd" {
  type    = number
  default = 300
}
variable "thresholds_percent" {
  type    = list(number)
  default = [50, 80, 95, 100]
}
variable "pubsub_topic_id" {
  description = "Optionnel — topic Pub/Sub pour automation auto-shutdown"
  type        = string
  default     = null
}
