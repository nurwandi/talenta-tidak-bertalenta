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
  description        = "Execution role for the talenta-tidak-bertalenta clock-in/clock-out Lambda functions"
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
  description   = "Talenta HR attendance ${each.key} — stealth Playwright browser running in ap-southeast-3 (Jakarta IP)"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = local.image
  architectures = ["arm64"]
  memory_size   = 2048
  timeout       = 120

  # Chromium writes shared memory to /tmp (via --disable-dev-shm-usage); give it room.
  ephemeral_storage {
    size = 2048
  }

  environment {
    variables = local.lambda_env
  }

  # Mirrors the Dockerfile's ENTRYPOINT/CMD/WORKDIR exactly (no behavior change) —
  # setting it explicitly stops the AWS console's "Cannot read ... 'ImageConfig'" error.
  image_config {
    entry_point       = ["npx", "aws-lambda-ric"]
    command           = ["handler.handler"]
    working_directory = "/var/task"
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

# EventBridge Scheduler invokes async; on failure Lambda retries 2× (3 runs) by
# default → triple clock attempts + triple Discord spam. The handler already
# retries internally 3×, so kill the async retries.
resource "aws_lambda_function_event_invoke_config" "clock" {
  for_each                     = aws_lambda_function.clock
  function_name                = each.value.function_name
  maximum_retry_attempts       = 0
  maximum_event_age_in_seconds = 300
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
  description        = "Role assumed by EventBridge Scheduler to invoke the attendance Lambda functions"
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

# --- Schedule group (taggable, unlike individual schedules; keeps them out of `default`) ---
resource "aws_scheduler_schedule_group" "this" {
  name = local.name
  tags = { Resource = "eventbridge" }
}

# --- Schedules (cron in Asia/Jakarta; aws_scheduler_schedule itself has no tags arg) ---
resource "aws_scheduler_schedule" "clock_in" {
  name        = "${local.name}-sched-in"
  description = "Trigger Talenta clock-in at 09:00 WIB, Monday-Friday"
  group_name  = aws_scheduler_schedule_group.this.name

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 9 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Jakarta"

  target {
    arn      = aws_lambda_function.clock["clock-in"].arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = "clock-in" })
  }
}

resource "aws_scheduler_schedule" "clock_out" {
  name        = "${local.name}-sched-out"
  description = "Trigger Talenta clock-out at 18:00 WIB, Monday-Friday"
  group_name  = aws_scheduler_schedule_group.this.name

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

# --- Failure alarm: email when a scheduled run errors. Fires off the platform
#     `Errors` metric, independent of the handler's Discord notify — so it also
#     catches silent failures (launch crash, timeout) the Discord path misses.
#     Only alarm_actions is set → email on failure only, never on success/recovery.
resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
  tags = { Resource = "sns" }
}

resource "aws_sns_topic_subscription" "alarm_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = aws_lambda_function.clock

  alarm_name          = "${each.value.function_name}-errors"
  alarm_description   = "A ${each.key} run errored — attendance may not have been recorded."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = { Resource = "cloudwatch" }
}
