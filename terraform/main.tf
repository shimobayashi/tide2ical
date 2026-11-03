data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  calendar_key = "tide.ics"
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
}

resource "aws_s3_bucket" "calendar" {
  bucket_prefix = "${var.name}-"
}

resource "aws_s3_bucket_public_access_block" "calendar" {
  bucket                  = aws_s3_bucket.calendar.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "calendar" {
  bucket = aws_s3_bucket.calendar.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "calendar" {
  name                              = var.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "calendar" {
  enabled         = true
  is_ipv6_enabled = true
  price_class     = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.calendar.bucket_regional_domain_name
    origin_id                = "calendar"
    origin_access_control_id = aws_cloudfront_origin_access_control.calendar.id
  }

  default_cache_behavior {
    target_origin_id       = "calendar"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 3600

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
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

data "aws_iam_policy_document" "calendar_read" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.calendar.arn}/${local.calendar_key}"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.calendar.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "calendar" {
  bucket = aws_s3_bucket.calendar.id
  policy = data.aws_iam_policy_document.calendar_read.json
}

resource "aws_sns_topic" "results" {
  name = "${var.name}-results"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.results.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sqs_queue" "scheduler_failures" {
  name                      = "${var.name}-scheduler-failures"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_cloudwatch_log_group" "generator" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "generator" {
  name               = "${var.name}-generator"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "generator" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.location_parameter_name}"]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.calendar.arn}/${local.calendar_key}"]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.generator.arn}:*"]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.results.arn]
  }
}

resource "aws_iam_role_policy" "generator" {
  role   = aws_iam_role.generator.id
  policy = data.aws_iam_policy_document.generator.json
}

data "archive_file" "generator" {
  type        = "zip"
  source_dir  = "${path.module}/../build/package"
  output_path = "${path.module}/../build/lambda.zip"
}

resource "aws_lambda_function" "generator" {
  function_name    = var.name
  role             = aws_iam_role.generator.arn
  runtime          = "ruby3.4"
  handler          = "lambda_function.lambda_handler"
  architectures    = ["x86_64"]
  filename         = data.archive_file.generator.output_path
  source_code_hash = data.archive_file.generator.output_base64sha256
  memory_size      = 256
  timeout          = 180

  environment {
    variables = {
      LOCATION_PARAMETER_NAME = var.location_parameter_name
      CALENDAR_DAYS           = tostring(var.calendar_days)
      CALENDAR_BUCKET         = aws_s3_bucket.calendar.id
      CALENDAR_KEY            = local.calendar_key
    }
  }

  depends_on = [aws_iam_role_policy.generator]
}

resource "aws_lambda_function_event_invoke_config" "generator" {
  function_name                = aws_lambda_function.generator.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 21600

  destination_config {
    on_failure {
      destination = aws_sns_topic.results.arn
    }
    on_success {
      destination = aws_sns_topic.results.arn
    }
  }
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_scheduler_schedule_group.calendar.arn]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.generator.arn]
  }
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.scheduler_failures.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule_group" "calendar" {
  name = var.name
}

resource "aws_scheduler_schedule" "calendar" {
  name                = var.name
  group_name          = aws_scheduler_schedule_group.calendar.name
  schedule_expression = "rate(30 days)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.generator.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = "{}"

    retry_policy {
      maximum_event_age_in_seconds = 21600
      maximum_retry_attempts       = 2
    }
    dead_letter_config {
      arn = aws_sqs_queue.scheduler_failures.arn
    }
  }

  depends_on = [aws_iam_role_policy.scheduler, aws_lambda_function_event_invoke_config.generator]
}
