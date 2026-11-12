data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Build the parameter ARN by hand instead of using a data source,
  # so the API key value is never read into Terraform state.
  api_key_param_arn = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.api_key_parameter_name}"
}

# ---------------------------------------------------------------
# SNS: where the briefing gets emailed
# ---------------------------------------------------------------
resource "aws_sns_topic" "briefing" {
  name = "${var.name_prefix}-topic"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.briefing.arn
  protocol  = "email"
  endpoint  = var.email
}

# ---------------------------------------------------------------
# Lambda: pulls feeds, asks Claude for a briefing, publishes to SNS
# ---------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/briefing.py"
  output_path = "${path.module}/build/briefing.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-lambda"
  retention_in_days = 14
}

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.name_prefix}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid      = "ReadApiKey"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = local.api_key_param_arn
      },
      {
        Sid      = "PublishBriefing"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.briefing.arn
      },
      {
        Sid      = "WriteRows"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.data.arn
      },
      {
        # Only usable through DynamoDB, not for calling KMS directly.
        Sid      = "UseTableKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.data.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "dynamodb.${data.aws_region.current.name}.amazonaws.com" }
        }
      }
    ]
  })
}

resource "aws_lambda_function" "briefing" {
  function_name    = "${var.name_prefix}-lambda"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "briefing.handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 90
  memory_size      = 128

  environment {
    variables = {
      API_KEY_PARAM   = var.api_key_parameter_name
      TOPIC_ARN       = aws_sns_topic.briefing.arn
      CLAUDE_MODEL    = var.claude_model
      MAX_TOKENS      = tostring(var.max_tokens)
      LOOKBACK_HOURS  = tostring(var.lookback_hours)
      FEEDS           = join(",", var.feeds)
      TABLE_NAME      = aws_dynamodb_table.data.name
      AGENT_NAME      = "tech-briefing"
      STATUS_TTL_DAYS = tostring(var.status_retention_days)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

# ---------------------------------------------------------------
# EventBridge Scheduler: runs the Lambda once a day, then nothing
# ---------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.name_prefix}-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.briefing.arn
    }]
  })
}

resource "aws_scheduler_schedule" "daily" {
  name                         = "${var.name_prefix}-daily"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.briefing.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts = 1
    }
  }
}
