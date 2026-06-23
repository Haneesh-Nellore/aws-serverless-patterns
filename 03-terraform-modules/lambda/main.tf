# modules/lambda/main.tf
# Reusable Lambda module — works identically across dev, staging, and prod.
# Application engineers call this module without needing to know IAM or CloudWatch details.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ─── Lambda Function ───────────────────────────────────────────────────────────

resource "aws_lambda_function" "this" {
  function_name = "${var.environment}-${var.function_name}"
  role          = aws_iam_role.lambda.arn
  handler       = var.handler
  runtime       = var.runtime
  timeout       = var.timeout_sec
  memory_size   = var.memory_mb

  filename         = var.zip_path
  source_code_hash = filebase64sha256(var.zip_path)

  environment {
    variables = merge(
      {
        ENVIRONMENT = var.environment
        LOG_LEVEL   = var.environment == "prod" ? "INFO" : "DEBUG"
      },
      var.env_vars
    )
  }

  # Limit concurrency to prevent DB connection storms
  reserved_concurrent_executions = var.reserved_concurrency

  tracing_config {
    mode = "Active" # X-Ray tracing enabled by default
  }

  tags = local.common_tags
}

# ─── IAM Role ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${var.environment}-${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# Basic execution: write logs to CloudWatch
resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Secrets Manager: read secrets (least privilege — read only)
resource "aws_iam_role_policy" "secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0
  name  = "secrets-read"
  role  = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.secret_arns
    }]
  })
}

# ─── CloudWatch Log Group ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${aws_lambda_function.this.function_name}"
  retention_in_days = var.environment == "prod" ? 90 : 14

  tags = local.common_tags
}

# ─── Alerts ───────────────────────────────────────────────────────────────────

# Alert when error rate exceeds threshold
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.environment}-${var.function_name}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = var.error_alarm_threshold
  alarm_description   = "Lambda error rate too high"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }

  alarm_actions = var.alarm_sns_arns
}

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Function    = var.function_name
  }
}
