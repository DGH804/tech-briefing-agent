# ---------------------------------------------------------------
# KMS: customer-managed key that encrypts the DynamoDB table
# ---------------------------------------------------------------
# Customer-managed = this aws_kms_key resource. You own its policy,
# rotation and deletion, and every use is logged in CloudTrail.
# No key policy is set, so AWS applies the default one: this account
# controls the key through IAM.
resource "aws_kms_key" "data" {
  description             = "${var.name_prefix} DynamoDB encryption key"
  enable_key_rotation     = true # new key material every year, old data still decrypts
  deletion_window_in_days = 30   # a scheduled delete can be cancelled for 30 days
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-data"
  target_key_id = aws_kms_key.data.key_id
}

# ---------------------------------------------------------------
# DynamoDB: table encrypted at rest with the key above
# ---------------------------------------------------------------
resource "aws_dynamodb_table" "data" {
  name         = "${var.name_prefix}-data"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "agent_name"
  range_key    = "timestamp"

  attribute {
    name = "agent_name"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  # Items expire once expires_at (epoch seconds, stored as a Number) passes.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # Which key encrypts the table:
  #   no server_side_encryption block -> AWS owned key (default, invisible to you)
  #   enabled = true, no kms_key_arn  -> AWS managed key (alias/aws/dynamodb)
  #   enabled = true + kms_key_arn    -> customer-managed key (this one)
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }
}
