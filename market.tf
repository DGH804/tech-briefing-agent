# ---------------------------------------------------------------
# Market review: weekday-morning email on index, sector and stock
# declines, from Massive (formerly Polygon.io) end-of-day data.
# Facts only, no buy or sell calls.
# ---------------------------------------------------------------
variable "market_api_key_parameter_name" {
  description = "SSM SecureString holding the Massive (Polygon.io) API key (created outside Terraform so it never lands in state)"
  type        = string
  default     = "/tech-briefing/market-api-key"
}

variable "market_api_base_url" {
  description = "Massive (Polygon.io) REST API base URL"
  type        = string
  default     = "https://api.polygon.io"
}

variable "market_schedule_expression" {
  description = "When the market review runs, in schedule_timezone. Default: 7:30 AM on weekdays, reviewing the previous trading day"
  type        = string
  default     = "cron(30 7 ? * MON-FRI *)"
}

variable "market_watchlist" {
  description = "Tickers to report on every run, e.g. [\"AAPL\", \"MSFT\"]"
  type        = list(string)
  default     = []
}

variable "market_watchlist_alert_pct" {
  description = "Mark a watchlist ticker ALERT when it falls this many percent or more in a day"
  type        = number
  default     = 3
}

variable "market_min_price" {
  description = "Decliner scan skips stocks that closed below this price (filters out penny stocks)"
  type        = number
  default     = 5
}

variable "market_min_dollar_volume" {
  description = "Decliner scan skips stocks that traded less than this many dollars on the day (keeps larger, liquid names)"
  type        = number
  default     = 50000000
}

variable "market_max_tokens" {
  description = "Cap on the length of Claude's market review"
  type        = number
  default     = 3000
}

locals {
  market_api_key_param_arn = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.market_api_key_parameter_name}"
}

# ---------------------------------------------------------------
# Lambda: pulls prices and news, asks Claude, publishes to SNS
# ---------------------------------------------------------------
data "archive_file" "market_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/market.py"
  output_path = "${path.module}/build/market.zip"
}

resource "aws_cloudwatch_log_group" "market" {
  name              = "/aws/lambda/${var.name_prefix}-market"
  retention_in_days = 14
}

resource "aws_iam_role" "market" {
  name = "${var.name_prefix}-market-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "market" {
  name = "${var.name_prefix}-market-policy"
  role = aws_iam_role.market.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.market.arn}:*"
      },
      {
        Sid      = "ReadApiKeys"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = [local.api_key_param_arn, local.market_api_key_param_arn]
      },
      {
        Sid      = "PublishReview"
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

resource "aws_lambda_function" "market" {
  function_name    = "${var.name_prefix}-market"
  role             = aws_iam_role.market.arn
  runtime          = "python3.13"
  handler          = "market.handler"
  filename         = data.archive_file.market_zip.output_path
  source_code_hash = data.archive_file.market_zip.output_base64sha256
  timeout          = 180 # free tier allows 5 calls a minute, so a run waits about a minute
  memory_size      = 256 # one day's prices for every US ticker is a large JSON response

  environment {
    variables = {
      API_KEY_PARAM     = var.api_key_parameter_name
      MARKET_KEY_PARAM  = var.market_api_key_parameter_name
      MARKET_API_BASE   = var.market_api_base_url
      TOPIC_ARN         = aws_sns_topic.briefing.arn
      CLAUDE_MODEL      = var.claude_model
      MAX_TOKENS        = tostring(var.market_max_tokens)
      WATCHLIST         = join(",", var.market_watchlist)
      ALERT_PCT         = tostring(var.market_watchlist_alert_pct)
      MIN_PRICE         = tostring(var.market_min_price)
      MIN_DOLLAR_VOLUME = tostring(var.market_min_dollar_volume)
      TABLE_NAME        = aws_dynamodb_table.data.name
      AGENT_NAME        = "market-review"
      STATUS_TTL_DAYS   = tostring(var.status_retention_days)
    }
  }

  depends_on = [aws_cloudwatch_log_group.market, aws_iam_role_policy.market]
}

# ---------------------------------------------------------------
# EventBridge Scheduler: weekday mornings
# ---------------------------------------------------------------
resource "aws_iam_role" "market_scheduler" {
  name = "${var.name_prefix}-market-scheduler-role"

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

resource "aws_iam_role_policy" "market_scheduler" {
  name = "${var.name_prefix}-market-scheduler-policy"
  role = aws_iam_role.market_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.market.arn
    }]
  })
}

resource "aws_scheduler_schedule" "market" {
  name                         = "${var.name_prefix}-market-weekdays"
  schedule_expression          = var.market_schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.market.arn
    role_arn = aws_iam_role.market_scheduler.arn

    retry_policy {
      maximum_retry_attempts = 1
    }
  }
}

output "market_lambda_name" {
  description = "Use this to trigger a test run"
  value       = aws_lambda_function.market.function_name
}
