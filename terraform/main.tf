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

# Keep only the last image (retention managed in Terraform for consistency).
resource "aws_ecr_lifecycle_policy" "this" {
  repository = data.aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last image"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 1
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

# --- Random delay: Step Functions acts as a free "sleep" in front of Lambda ---
# Scheduler's flexible window picks a FIXED offset per schedule (observed: clock-in
# always 09:05:37, clock-out always 18:23:44), not a new random one each day.
# A Standard state machine Wait is free while waiting and has no 15-min cap, so:
# random 0-1800s -> Wait -> invoke Lambda synchronously.
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${local.name}-sfn-role"
  description        = "Role assumed by the random-delay state machine to invoke the attendance Lambda functions"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = { Resource = "iam" }
}

resource "aws_iam_role_policy" "sfn_invoke" {
  name = "${local.name}-sfn-invoke"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [for f in aws_lambda_function.clock : f.arn]
    }]
  })
}

resource "aws_sfn_state_machine" "clock" {
  name     = "${local.name}-clock"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD" # Express bills duration and caps at 5 min — Standard bills per transition only

  definition = jsonencode({
    Comment = "Wait a random 0-30 min, then run clock-in/clock-out"
    StartAt = "PickDelay"
    States = {
      PickDelay = {
        Type = "Pass"
        Parameters = {
          "action.$" = "$.action"
          "delay.$"  = "States.MathRandom(0, 1800)"
        }
        Next = "RandomWait"
      }
      RandomWait = {
        Type        = "Wait"
        SecondsPath = "$.delay"
        Next        = "Clock"
      }
      Clock = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          "FunctionName.$" = "States.Format('${local.name}-{}', $.action)"
          "Payload" = {
            "action.$" = "$.action"
          }
        }
        # Only retry Lambda-service hiccups (function never ran). Handler errors are
        # NOT retried — the handler already retries 3x internally; a rerun = double clock.
        Retry = [{
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 5
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        End = true
      }
    }
  })

  tags = { Resource = "stepfunctions" }
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
  description        = "Role assumed by EventBridge Scheduler to start the random-delay state machine"
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
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.clock.arn
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
  description = "Trigger Talenta clock-in between 09:00-09:30 WIB, Monday-Friday"
  group_name  = aws_scheduler_schedule_group.this.name

  # Manual kill switch: flip to DISABLED with ./toggle.sh off before a holiday/leave.
  # ignore_changes keeps that manual toggle from being reverted on the next apply.
  state = "ENABLED"
  lifecycle {
    ignore_changes = [state]
  }

  # Fires exactly on the cron time; the 0-30 min randomness comes from the state machine.
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 9 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Jakarta"

  target {
    arn      = aws_sfn_state_machine.clock.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = "clock-in" })
  }
}

resource "aws_scheduler_schedule" "clock_out" {
  name        = "${local.name}-sched-out"
  description = "Trigger Talenta clock-out between 18:00-18:30 WIB, Monday-Friday"
  group_name  = aws_scheduler_schedule_group.this.name

  # Manual kill switch — see clock_in above.
  state = "ENABLED"
  lifecycle {
    ignore_changes = [state]
  }

  # Fires exactly on the cron time; the 0-30 min randomness comes from the state machine.
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 18 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Jakarta"

  target {
    arn      = aws_sfn_state_machine.clock.arn
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
