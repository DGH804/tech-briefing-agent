output "lambda_name" {
  description = "Use this to trigger a test run"
  value       = aws_lambda_function.briefing.function_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.briefing.arn
}

output "schedule" {
  value = "${var.schedule_expression} (${var.schedule_timezone})"
}

output "kms_key_arn" {
  description = "Customer-managed key that encrypts the DynamoDB table"
  value       = aws_kms_key.data.arn
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.data.name
}
