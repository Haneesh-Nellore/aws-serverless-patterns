# modules/lambda/variables.tf

variable "function_name" {
  description = "Name of the Lambda function (environment prefix added automatically)"
  type        = string
}

variable "environment" {
  description = "Deployment environment: dev | staging | prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}

variable "handler" {
  description = "Lambda handler entrypoint (e.g. 'index.handler' or 'com.example.Handler::handleRequest')"
  type        = string
}

variable "runtime" {
  description = "Lambda runtime (e.g. 'java21', 'python3.12', 'nodejs20.x')"
  type        = string
  default     = "python3.12"
}

variable "zip_path" {
  description = "Path to the deployment ZIP file"
  type        = string
}

variable "memory_mb" {
  description = "Lambda memory in MB (128–10240)"
  type        = number
  default     = 256
  validation {
    condition     = var.memory_mb >= 128 && var.memory_mb <= 10240
    error_message = "memory_mb must be between 128 and 10240"
  }
}

variable "timeout_sec" {
  description = "Lambda timeout in seconds (max 900)"
  type        = number
  default     = 30
}

variable "reserved_concurrency" {
  description = "Reserved concurrency limit (-1 = unreserved, 0 = throttled)"
  type        = number
  default     = -1
}

variable "env_vars" {
  description = "Environment variables to pass to the Lambda function"
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = "ARNs of Secrets Manager secrets this Lambda needs to read"
  type        = list(string)
  default     = []
}

variable "error_alarm_threshold" {
  description = "Number of errors per minute before CloudWatch alarm fires"
  type        = number
  default     = 5
}

variable "alarm_sns_arns" {
  description = "SNS topic ARNs to notify when alarms fire (e.g. PagerDuty)"
  type        = list(string)
  default     = []
}
