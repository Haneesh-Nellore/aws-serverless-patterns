# modules/sqs-worker/main.tf
# Wires up an SQS queue → Lambda worker with DLQ and all the right settings.
# Drop this module in and you get a production-ready async job processor.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ─── Dead Letter Queue ────────────────────────────────────────────────────────

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.environment}-${var.queue_name}-dlq"
  message_retention_seconds = 1209600 # 14 days — enough time to investigate failures

  tags = local.common_tags
}

# ─── Main Queue ───────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "main" {
  name = "${var.environment}-${var.queue_name}"

  # Must be >= Lambda timeout to prevent duplicate processing
  visibility_timeout_seconds = var.lambda_timeout_sec + 30

  message_retention_seconds = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count # retry N times before sending to DLQ
  })

  tags = local.common_tags
}

# ─── Lambda Trigger ───────────────────────────────────────────────────────────

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = var.lambda_arn
  batch_size       = var.batch_size
  enabled          = true

  # Partial batch failure: only failed messages go back to queue
  # Successful messages in the same batch are NOT reprocessed
  function_response_types = ["ReportBatchItemFailures"]
}

# ─── IAM: Allow Lambda to read from this queue ────────────────────────────────

resource "aws_iam_role_policy" "sqs_read" {
  name = "${var.environment}-${var.queue_name}-sqs-read"
  role = var.lambda_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility"
      ]
      Resource = [
        aws_sqs_queue.main.arn,
        aws_sqs_queue.dlq.arn
      ]
    }]
  })
}

# ─── DLQ Alarm: alert when jobs land in DLQ ──────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.environment}-${var.queue_name}-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages in DLQ — jobs are failing after max retries"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  alarm_actions = var.alarm_sns_arns
}

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Queue       = var.queue_name
  }
}
