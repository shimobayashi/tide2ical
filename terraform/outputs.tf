output "calendar_url" {
  value     = "https://${aws_cloudfront_distribution.calendar.domain_name}/${local.calendar_key}"
  sensitive = true
}

output "function_name" {
  value = aws_lambda_function.generator.function_name
}

output "calendar_bucket" {
  value     = aws_s3_bucket.calendar.id
  sensitive = true
}

output "scheduler_failure_queue_url" {
  value     = aws_sqs_queue.scheduler_failures.url
  sensitive = true
}
