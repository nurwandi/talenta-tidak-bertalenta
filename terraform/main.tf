data "aws_caller_identity" "current" {}

locals {
  name  = "talenta-tidak-bertalenta"
  image = "${data.aws_ecr_repository.this.repository_url}:${var.image_tag}"

  lambda_env = {
    TALENTA_EMAIL       = var.talenta_email
    TALENTA_PASSWORD    = var.talenta_password
    DISCORD_WEBHOOK_URL = var.discord_webhook_url
    DISCORD_USER_ID     = var.discord_user_id
    HEADLESS            = "true"
    HOME                = "/tmp"
    TZ                  = "Asia/Jakarta"
  }
}

# --- ECR (repo created out-of-band by build-push.sh; read-only here) ---
data "aws_ecr_repository" "this" {
  name = local.name
}

# Keep only the last 2 images (retention managed in Terraform for consistency).
resource "aws_ecr_lifecycle_policy" "this" {
  repository = data.aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 2 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 2
      }
      action = { type = "expire" }
    }]
  })
}

# --- Lambda execution role (shared by both functions) ---
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Resource = "iam" }
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- Lambda functions (share one image) ---
resource "aws_lambda_function" "clock" {
  for_each = toset(["clock-in", "clock-out"])

  function_name = "${local.name}-${each.key}"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = local.image
  architectures = ["x86_64"]
  memory_size   = 2048
  timeout       = 120

  environment {
    variables = local.lambda_env
  }

  tags = { Resource = "lambda" }
}

# --- Log groups (managed so they carry tags + retention) ---
resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = aws_lambda_function.clock
  name              = "/aws/lambda/${each.value.function_name}"
  retention_in_days = 14
  tags              = { Resource = "lambda" }
}

# --- EventBridge Scheduler invoke role ---
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = { Resource = "iam" }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "${local.name}-scheduler-invoke"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [for f in aws_lambda_function.clock : f.arn]
    }]
  })
}

# --- Schedules (cron in Asia/Jakarta; aws_scheduler_schedule has no tags arg) ---
resource "aws_scheduler_schedule" "clock_in" {
  name = "${local.name}-sched-in"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 8 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Jakarta"

  target {
    arn      = aws_lambda_function.clock["clock-in"].arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = "clock-in" })
  }
}

resource "aws_scheduler_schedule" "clock_out" {
  name = "${local.name}-sched-out"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 18 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Jakarta"

  target {
    arn      = aws_lambda_function.clock["clock-out"].arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = "clock-out" })
  }
}
