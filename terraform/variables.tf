variable "aws_region" {
  type    = string
  default = "ap-southeast-3"
}

variable "image_tag" {
  type        = string
  description = "Immutable ECR image tag the Lambdas run (e.g. v1)."
  default     = "v1"
}

variable "talenta_email" {
  type      = string
  sensitive = true
}

variable "talenta_password" {
  type      = string
  sensitive = true
}

variable "discord_webhook_url" {
  type      = string
  sensitive = true
}

variable "discord_user_id" {
  type    = string
  default = "710595837067264082"
}
