terraform {
  required_version = ">= 0.14"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 3.27" }
  }
}

# Opinionated private bucket: encrypted, versioned, TLS-only, never public.
resource "aws_s3_bucket" "this" {
  bucket        = var.name
  force_destroy = var.force_destroy

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
        kms_master_key_id = var.kms_key_arn
      }
    }
  }

  lifecycle_rule {
    id                                     = "noncurrent-cleanup"
    enabled                                = true
    abort_incomplete_multipart_upload_days = 7
    noncurrent_version_expiration {
      days = var.noncurrent_retention_days
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.expire_after_days == null ? [] : [var.expire_after_days]
    content {
      id      = "expire-current"
      enabled = true
      expiration {
        days = lifecycle_rule.value
      }
    }
  }

  tags = merge(var.tags, { Module = "s3-bucket" })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = var.allow_log_delivery ? [1] : []
    content {
      sid       = "AWSLogDeliveryWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.this.arn}/*"]
      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}
