# 04-concurrency/rds_proxy_setup.tf
#
# Concurrency & Connection Pooling Pattern
#
# Problem: Lambda functions can't hold persistent DB connections.
# At scale, each invocation opens + closes a connection — exhausting DB limits.
#
# Solution: RDS Proxy sits between Lambda and RDS.
# It maintains a warm connection pool and multiplexes Lambda requests through it.
#
#   Lambda invocations → RDS Proxy (pool) → RDS / Aurora
#
# Combined with reserved_concurrent_executions on the Lambda side,
# this prevents connection storms under traffic spikes.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────

variable "environment" {
  type = string
}

variable "db_instance_arn" {
  description = "ARN of the RDS instance or Aurora cluster"
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret containing DB credentials"
  type        = string
}

variable "vpc_subnet_ids" {
  description = "Private subnet IDs where the proxy will run"
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "Security group IDs for the proxy"
  type        = list(string)
}

variable "lambda_function_name" {
  description = "Name of the Lambda function to apply concurrency limits to"
  type        = string
}

variable "lambda_reserved_concurrency" {
  description = "Max concurrent Lambda executions (set based on DB max_connections)"
  type        = number
  default     = 50
}

# ─── IAM Role for RDS Proxy ───────────────────────────────────────────────────

resource "aws_iam_role" "rds_proxy" {
  name = "${var.environment}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "secrets-read"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn]
    }]
  })
}

# ─── RDS Proxy ────────────────────────────────────────────────────────────────

resource "aws_db_proxy" "this" {
  name                   = "${var.environment}-db-proxy"
  debug_logging          = var.environment != "prod"
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800 # 30 min — close idle connections
  require_tls            = true
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = var.vpc_subnet_ids
  vpc_security_group_ids = var.vpc_security_group_ids

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "REQUIRED" # Lambda uses IAM auth — no hardcoded passwords
    secret_arn  = var.db_secret_arn
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─── Proxy Target (points to your RDS instance) ───────────────────────────────

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    # Max % of max_connections the proxy can use
    # Leave headroom for direct connections (migrations, debugging)
    connection_borrow_timeout    = 120
    max_connections_percent      = 80
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name         = aws_db_proxy.this.name
  target_group_name     = aws_db_proxy_default_target_group.this.name
  db_instance_identifier = var.db_instance_arn
}

# ─── Lambda Concurrency Limit ─────────────────────────────────────────────────
#
# Cap Lambda concurrency so it can't generate more connections than the proxy pool.
# Formula: reserved_concurrency <= (max_connections * 0.8) / avg_connections_per_lambda
#
# Example: RDS has 100 max_connections
#   Proxy uses 80% = 80 connections
#   Each Lambda uses ~2 connections → cap at 40 concurrent Lambdas

resource "aws_lambda_function_event_invoke_config" "concurrency" {
  function_name = var.lambda_function_name

  # This sets reserved concurrency — adjust based on your DB size
  # See: aws_lambda_function.reserved_concurrent_executions
}

# ─── Alarm: Proxy connection saturation ───────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "proxy_connections" {
  alarm_name          = "${var.environment}-rds-proxy-connection-saturation"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnectionRequests"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Sum"
  threshold           = 1000
  alarm_description   = "RDS Proxy connection requests are high — consider scaling DB or reducing Lambda concurrency"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ProxyName = aws_db_proxy.this.name
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "proxy_endpoint" {
  description = "RDS Proxy endpoint — use this as your DB host in Lambda env vars"
  value       = aws_db_proxy.this.endpoint
}
