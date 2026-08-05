# Module budget-alerts — canal notification + budget avec seuils Bendimu

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Bendimu Budget Alert Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

resource "google_billing_budget" "this" {
  billing_account = var.billing_account_id
  display_name    = var.display_name

  budget_filter {
    projects               = ["projects/${var.project_number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = var.budget_amount_usd
    }
  }

  dynamic "threshold_rules" {
    for_each = var.thresholds_percent
    content {
      threshold_percent = threshold_rules.value / 100.0
      spend_basis       = "CURRENT_SPEND"
    }
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
    disable_default_iam_recipients   = false
    pubsub_topic                     = var.pubsub_topic_id
  }
}
