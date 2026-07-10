variable "aws_region" {
  type        = string
  description = "AWS region for all resources (Jakarta, for an Indonesian outbound IP)."
  default     = "ap-southeast-3"
}

variable "image_tag" {
  type        = string
  description = "Immutable ECR image tag the Lambdas run (e.g. v1)."
  default     = "v1"
}

variable "talenta_email" {
  type        = string
  description = "Talenta HR login email (set as an HCP sensitive workspace variable)."
  sensitive   = true
}

variable "talenta_password" {
  type        = string
  description = "Talenta HR login password (set as an HCP sensitive workspace variable)."
  sensitive   = true
}

variable "discord_webhook_url" {
  type        = string
  description = "Discord webhook URL for success/failure notifications (HCP sensitive var)."
  sensitive   = true
}

variable "discord_user_id" {
  type        = string
  description = "Discord user ID to @mention in notifications."
  default     = "710595837067264082"
}
