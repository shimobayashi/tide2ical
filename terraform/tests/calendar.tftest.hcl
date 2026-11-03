mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/example"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:ap-northeast-1:123456789012:example"
    }
  }
  mock_resource "aws_sqs_queue" {
    defaults = {
      arn = "arn:aws:sqs:ap-northeast-1:123456789012:example"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:ap-northeast-1:123456789012:function:example"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  notification_email = "test@example.com"
}

run "calendar_configuration" {
  command = plan

  assert {
    condition     = aws_scheduler_schedule.calendar.schedule_expression == "rate(30 days)"
    error_message = "実行間隔が30日ではありません。"
  }
  assert {
    condition     = aws_lambda_function.generator.environment[0].variables.LOCATION_PARAMETER_NAME == "/tide2ical/location" && aws_lambda_function.generator.environment[0].variables.CALENDAR_DAYS == "90"
    error_message = "SSM の設定で90日分を生成する構成ではありません。"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.calendar.block_public_acls && aws_s3_bucket_public_access_block.calendar.block_public_policy && aws_s3_bucket_public_access_block.calendar.ignore_public_acls && aws_s3_bucket_public_access_block.calendar.restrict_public_buckets
    error_message = "S3 の直接公開が許可されています。"
  }
  assert {
    condition     = !contains(keys(aws_lambda_function.generator.environment[0].variables), "PREFECTURE_CODE") && !contains(keys(aws_lambda_function.generator.environment[0].variables), "HARBOR_CODE")
    error_message = "地域の値を Lambda の環境変数ではなく SSM から読んでください。"
  }
  assert {
    condition     = aws_cloudfront_origin_access_control.calendar.signing_behavior == "always" && one(aws_cloudfront_distribution.calendar.default_cache_behavior).viewer_protocol_policy == "https-only"
    error_message = "HTTPS と CloudFront から S3 への認証が必要です。"
  }
  assert {
    condition     = aws_lambda_function_event_invoke_config.generator.maximum_retry_attempts == 2 && aws_scheduler_schedule.calendar.target[0].retry_policy[0].maximum_retry_attempts == 2
    error_message = "Lambda または Scheduler の再試行が設定されていません。"
  }
}
