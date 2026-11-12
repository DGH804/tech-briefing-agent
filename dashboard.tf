# ---------------------------------------------------------------
# Dashboard: read-only status view of the agents.
# Browser -> CloudFront (page from private S3) -> Cognito login
#         -> API Gateway (JWT) -> read-only Lambda -> DynamoDB
# Nothing in this file can write to the status table.
# ---------------------------------------------------------------
variable "dashboard_agents" {
  description = "Agent names the dashboard shows. Agents with no rows show as idle."
  type        = list(string)
  default     = ["tech-briefing", "market-review"]
}

variable "dashboard_watch_window" {
  description = "Time window (HH:MM in schedule_timezone, same day) when the dashboard checks every 2 s to catch the scheduled run live. Keep it around schedule_expression."
  type        = object({ start = string, end = string })
  default     = { start = "06:59", end = "07:05" }

  validation {
    condition = alltrue([
      for t in [var.dashboard_watch_window.start, var.dashboard_watch_window.end] :
      can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", t))
    ])
    error_message = "start and end must be 24-hour HH:MM, e.g. 06:59."
  }
}

locals {
  dashboard_origin = "https://${aws_cloudfront_distribution.dashboard.domain_name}"
  cognito_domain   = "${aws_cognito_user_pool_domain.dashboard.domain}.auth.${data.aws_region.current.name}.amazoncognito.com"
}

# ---------------------------------------------------------------
# Read-only Lambda: queries the latest rows per agent
# ---------------------------------------------------------------
data "archive_file" "dashboard_api_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/dashboard_api.py"
  output_path = "${path.module}/build/dashboard_api.zip"
}

resource "aws_cloudwatch_log_group" "dashboard_api" {
  name              = "/aws/lambda/${var.name_prefix}-dashboard-api"
  retention_in_days = 14
}

resource "aws_iam_role" "dashboard_api" {
  name = "${var.name_prefix}-dashboard-api-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "dashboard_api" {
  name = "${var.name_prefix}-dashboard-api-policy"
  role = aws_iam_role.dashboard_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.dashboard_api.arn}:*"
      },
      {
        # Read only. No Scan, no writes.
        Sid      = "ReadStatus"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.data.arn
      },
      {
        # Only usable through DynamoDB, not for calling KMS directly.
        Sid      = "DecryptViaTable"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.data.arn
        Condition = {
          StringEquals = { "kms:ViaService" = "dynamodb.${data.aws_region.current.name}.amazonaws.com" }
        }
      }
    ]
  })
}

resource "aws_lambda_function" "dashboard_api" {
  function_name    = "${var.name_prefix}-dashboard-api"
  role             = aws_iam_role.dashboard_api.arn
  runtime          = "python3.13"
  handler          = "dashboard_api.handler"
  filename         = data.archive_file.dashboard_api_zip.output_path
  source_code_hash = data.archive_file.dashboard_api_zip.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.data.name
      AGENTS        = join(",", var.dashboard_agents)
      STALE_SECONDS = "120" # a run still "running" after 2 minutes shows as timed out
      MAX_TOKENS    = tostring(var.max_tokens)
    }
  }

  depends_on = [aws_cloudwatch_log_group.dashboard_api, aws_iam_role_policy.dashboard_api]
}

# ---------------------------------------------------------------
# Cognito: one user (you), no self-signup, hosted login page
# ---------------------------------------------------------------
resource "aws_cognito_user_pool" "dashboard" {
  name                     = "${var.name_prefix}-dashboard"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"

  admin_create_user_config {
    allow_admin_create_user_only = true # self-signup disabled
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

# Cognito emails you a temporary password; it never lands in state.
# Lowercased because this pool's usernames are case-sensitive.
resource "aws_cognito_user" "me" {
  user_pool_id             = aws_cognito_user_pool.dashboard.id
  username                 = lower(var.email)
  desired_delivery_mediums = ["EMAIL"]

  attributes = {
    email          = lower(var.email)
    email_verified = "true"
  }
}

# Hosted login page at https://<prefix>.auth.<region>.amazoncognito.com
resource "aws_cognito_user_pool_domain" "dashboard" {
  domain       = "${var.name_prefix}-${substr(sha1(data.aws_caller_identity.current.account_id), 0, 8)}"
  user_pool_id = aws_cognito_user_pool.dashboard.id
}

# Public browser client: authorization code flow with PKCE, no secret.
resource "aws_cognito_user_pool_client" "dashboard" {
  name         = "${var.name_prefix}-dashboard"
  user_pool_id = aws_cognito_user_pool.dashboard.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["${local.dashboard_origin}/"]
  logout_urls                          = ["${local.dashboard_origin}/"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 12

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}

# ---------------------------------------------------------------
# API Gateway HTTP API: GET /status, Cognito JWT required
# ---------------------------------------------------------------
resource "aws_apigatewayv2_api" "dashboard" {
  name          = "${var.name_prefix}-dashboard"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = [local.dashboard_origin]
    allow_methods = ["GET"]
    allow_headers = ["authorization"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.dashboard.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = "https://${aws_cognito_user_pool.dashboard.endpoint}"
    audience = [aws_cognito_user_pool_client.dashboard.id]
  }
}

resource "aws_apigatewayv2_integration" "dashboard_api" {
  api_id                 = aws_apigatewayv2_api.dashboard.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.dashboard_api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "status" {
  api_id             = aws_apigatewayv2_api.dashboard.id
  route_key          = "GET /status"
  target             = "integrations/${aws_apigatewayv2_integration.dashboard_api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.dashboard.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

resource "aws_lambda_permission" "dashboard_api" {
  statement_id  = "AllowApiGatewayStatus"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dashboard_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.dashboard.execution_arn}/*/GET/status"
}

# ---------------------------------------------------------------
# S3: private bucket holding the one HTML page
# ---------------------------------------------------------------
resource "aws_s3_bucket" "dashboard" {
  bucket = "${var.name_prefix}-dashboard-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Only this CloudFront distribution can read the bucket.
resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudFrontReadOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.dashboard.arn }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.dashboard]
}

locals {
  dashboard_page = templatefile("${path.module}/dashboard/index.html.tpl", {
    api_url        = aws_apigatewayv2_api.dashboard.api_endpoint
    cognito_domain = local.cognito_domain
    client_id      = aws_cognito_user_pool_client.dashboard.id
    watch_timezone = var.schedule_timezone
    watch_start    = var.dashboard_watch_window.start
    watch_end      = var.dashboard_watch_window.end
  })
}

resource "aws_s3_object" "dashboard_page" {
  bucket        = aws_s3_bucket.dashboard.id
  key           = "index.html"
  content       = local.dashboard_page
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
  etag          = md5(local.dashboard_page)
}

# ---------------------------------------------------------------
# CloudFront: HTTPS in front of the bucket, via Origin Access Control
# ---------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "dashboard" {
  name                              = "${var.name_prefix}-dashboard"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_response_headers_policy" "dashboard" {
  name = "${var.name_prefix}-dashboard"

  security_headers_config {
    content_security_policy {
      override = true
      content_security_policy = join("; ", [
        "default-src 'none'",
        "script-src 'unsafe-inline'",
        "style-src 'unsafe-inline'",
        # API by region wildcard: naming the API itself would make a cycle
        # (API CORS -> CloudFront domain -> this policy -> API).
        "connect-src https://*.execute-api.${data.aws_region.current.name}.amazonaws.com https://${local.cognito_domain}",
        "img-src data:",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
      ])
    }

    strict_transport_security {
      override                   = true
      access_control_max_age_sec = 31536000
      include_subdomains         = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      override     = true
      frame_option = "DENY"
    }

    referrer_policy {
      override        = true
      referrer_policy = "no-referrer"
    }
  }
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  comment             = "${var.name_prefix} dashboard"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "dashboard-s3"
    domain_name              = aws_s3_bucket.dashboard.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  default_cache_behavior {
    target_origin_id           = "dashboard-s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.dashboard.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "dashboard_url" {
  value = "${local.dashboard_origin}/"
}

output "dashboard_api_url" {
  value = "${aws_apigatewayv2_api.dashboard.api_endpoint}/status"
}
