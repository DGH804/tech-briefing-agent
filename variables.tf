variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name"
  type        = string
  default     = "tech-briefing-tf"
}

variable "email" {
  description = "Email address that receives the daily briefing (confirm the SNS subscription email after apply)"
  type        = string
}

variable "schedule_expression" {
  description = "EventBridge Scheduler expression. Default: every day at 7:00 AM"
  type        = string
  default     = "cron(0 7 * * ? *)"
}

variable "schedule_timezone" {
  description = "Time zone the schedule runs in"
  type        = string
  default     = "America/New_York"
}

variable "api_key_parameter_name" {
  description = "Name of the SSM SecureString parameter holding the Claude API key (created outside Terraform so the key never lands in state)"
  type        = string
  default     = "/tech-briefing/anthropic-api-key"
}

variable "claude_model" {
  description = "Claude model used to write the briefing. Haiku keeps cost lowest"
  type        = string
  default     = "claude-haiku-5-5"
}

variable "max_tokens" {
  description = "Cap on the length of Claude's reply (keeps spend predictable)"
  type        = number
  default     = 1200
}

variable "lookback_hours" {
  description = "Only include articles published in the last N hours"
  type        = number
  default     = 26
}

variable "status_retention_days" {
  description = "How long each status row stays in DynamoDB before TTL removes it"
  type        = number
  default     = 30
}

variable "feeds" {
  description = "RSS/Atom feeds to pull AI news from"
  type        = list(string)
  default = [
    "https://techcrunch.com/category/artificial-intelligence/feed/",
    "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml",
    "https://arstechnica.com/ai/feed/",
    "https://venturebeat.com/category/ai/feed/",
    "https://www.technologyreview.com/topic/artificial-intelligence/feed",
  ]
}
