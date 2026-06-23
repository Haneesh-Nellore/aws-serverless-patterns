# modules/sqs-worker/variables.tf

variable "queue_name" {
  description = "Name of the SQS queue (environment prefix added automatically)"
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

variable "lambda_arn" {
  description = "ARN of the Lambda function that will process messages"
  type        = string
}

variable "lambda_role_name" {
  description = "IAM role name of the Lambda (to attach SQS read permissions)"
  type        = string
}

variable "lambda_timeout_sec" {
  description = "Timeout of the worker Lambda in seconds (used to set queue visibility timeout)"
  type        = number
  default     = 30
}

variable "batch_size" {
  description = "Number of SQS messages to send to Lambda per invocation (1–10000)"
  type        = number
  default     = 10
}

variable "max_receive_count" {
  description = "Number of times a message is retried before going to the DLQ"
  type        = number
  default     = 3
}

variable "alarm_sns_arns" {
  description = "SNS topic ARNs to notify when DLQ alarm fires"
  type        = list(string)
  default     = []
}
