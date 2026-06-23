# aws-serverless-patterns
Production-tested AWS serverless patterns, Lambda, SQS, Terraform, and more.

# AWS Serverless Patterns

A collection of production-tested patterns for building scalable, cost-efficient serverless systems on AWS — based on real-world infrastructure work across enterprise-grade applications.

These patterns cover the decisions, trade-offs, and configurations that actually matter in production: not just "how to deploy a Lambda," but how to make it survive real traffic, stay cheap, and not wake you up at 3am.

---

## What's Inside

| Pattern | Description |
|---|---|
| [Lambda Cold Start Tuning](#1-lambda-cold-start-tuning) | Minimize cold start latency for user-facing endpoints |
| [SQS-Triggered Async Jobs](#2-sqs-triggered-async-job-pattern) | Decouple heavy background work from your main API |
| [Kubernetes → Lambda Migration](#3-kubernetes--lambda-migration-guide) | Cut infrastructure costs by 60–70% with the right refactor |
| [Terraform Modular Configs](#4-terraform-modular-configs) | Reusable IaC across dev, staging, and prod |
| [Concurrency & Connection Pooling](#5-concurrency--connection-pooling) | Handle traffic spikes without manual intervention |

---

## 1. Lambda Cold Start Tuning

**The problem:** After migrating services from always-on containers to Lambda, cold starts caused noticeable latency on user-facing endpoints — especially for Java-based functions where JVM startup is slow.

**What works in production:**

- Use **Provisioned Concurrency** selectively — only on the endpoints where latency is user-visible. Don't provision everything; it defeats the cost savings.
- Keep your **deployment package lean**. Strip unused dependencies. For Java, avoid loading the full Spring context on init — use lightweight DI or lazy initialization.
- Move expensive init work (DB connections, config loading) **outside the handler function** so it runs once per container lifecycle, not per invocation.
- Use **Lambda SnapStart** (for Java 21 runtimes) to snapshot the initialized execution environment and restore it on cold start.

```java
// ❌ Bad: connection created inside handler (every invocation)
public String handleRequest(Map<String, String> event, Context context) {
    Connection conn = DriverManager.getConnection(DB_URL); // cold and warm both pay this cost
    ...
}

// ✅ Good: connection created at class load time (once per container)
private static final Connection conn = DriverManager.getConnection(DB_URL);

public String handleRequest(Map<String, String> event, Context context) {
    // reuse conn
}
```

**Result:** Sub-200ms p99 latency on user-facing Java Lambdas under real traffic.

---

## 2. SQS-Triggered Async Job Pattern

**The problem:** Background jobs (report generation, data sync, notifications) were running inside the main API Lambda. Under traffic bursts, they caused timeouts and cascading failures on user-facing endpoints.

**The pattern:**

```
API Lambda  →  SQS Queue  →  Worker Lambda
(fast, user-facing)         (slow, async, isolated)
```

- API Lambda does the minimum: validate, enqueue the job, return 202 Accepted immediately.
- SQS handles buffering and retry logic automatically.
- Worker Lambda processes jobs independently — failures don't affect the API.
- Set a **Dead Letter Queue (DLQ)** on the SQS queue to catch jobs that fail after max retries.

**Key configs that matter:**

```hcl
resource "aws_sqs_queue" "job_queue" {
  name                       = "background-jobs"
  visibility_timeout_seconds = 300        # must be >= your Lambda timeout
  message_retention_seconds  = 86400      # 1 day
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = aws_sqs_queue.job_queue.arn
  function_name                      = aws_lambda_function.worker.arn
  batch_size                         = 10
  function_response_types            = ["ReportBatchItemFailures"] # partial batch success
}
```

**Result:** Pod crash incidents dropped to zero. System scales to zero off-peak automatically.

---

## 3. Kubernetes → Lambda Migration Guide

**When it makes sense:**

Kubernetes is the right tool when you have long-running, stateful workloads with consistently high traffic. It becomes expensive overhead when your services are:
- Idle for significant periods (nights, weekends)
- Stateless and request-scoped
- Under 15 minutes per execution

**The migration process:**

1. **Audit your services.** Identify which pods are actually idle >50% of the time using CloudWatch or Datadog metrics.
2. **Refactor for statelessness.** Lambdas can't hold in-memory state between invocations. Move session state to Redis or DynamoDB.
3. **Handle cold starts** (see Pattern 1 above).
4. **Move connection management outside the handler.**
5. **Replace cron jobs** with EventBridge Scheduler → Lambda.
6. **Replace always-on workers** with SQS → Lambda (see Pattern 2).
7. **Update your IaC** — retire the K8s manifests, write Terraform for the Lambda resources.
8. **Run both in parallel** for one release cycle before decommissioning the pods.

**Cost reality check:**

| | Kubernetes (EKS) | Lambda |
|---|---|---|
| Idle cost | Pay for nodes 24/7 | $0 |
| Peak scaling | Manual or HPA lag | Automatic, instant |
| Ops overhead | Node management, upgrades | Near zero |
| Best for | Sustained high throughput | Spiky or low traffic |

**Result:** 60–70% infrastructure cost reduction on services that were running 24/7 on K8s with minimal off-peak traffic.

---

## 4. Terraform Modular Configs

**The problem:** AWS environments were provisioned manually with no record of what ran where. Each new environment required someone senior to remember the steps.

**The pattern — modular Terraform that works identically across environments:**

```
infrastructure/
├── modules/
│   ├── lambda/          # reusable Lambda + IAM + CloudWatch
│   ├── api-gateway/     # REST API + stages + throttling
│   ├── sqs-worker/      # queue + DLQ + Lambda trigger
│   └── vpc/             # networking baseline
├── environments/
│   ├── dev/
│   │   └── main.tf      # calls modules with dev vars
│   ├── staging/
│   │   └── main.tf
│   └── prod/
│       └── main.tf
└── variables.tf
```

**Key principle — the module interface:**

```hcl
# modules/lambda/variables.tf
variable "function_name" { type = string }
variable "memory_mb"     { type = number; default = 256 }
variable "timeout_sec"   { type = number; default = 30 }
variable "environment"   { type = string }  # dev | staging | prod
variable "env_vars"      { type = map(string); default = {} }
```

```hcl
# environments/prod/main.tf
module "api_lambda" {
  source        = "../../modules/lambda"
  function_name = "api-handler"
  memory_mb     = 512
  timeout_sec   = 29
  environment   = "prod"
  env_vars = {
    DB_SECRET_ARN = aws_secretsmanager_secret.db.arn
  }
}
```

**Result:** Environment setup went from days to under an hour. Passed cloud governance audits with no manual exceptions.

---

## 5. Concurrency & Connection Pooling

**The problem:** After the Lambda migration, peak traffic caused slow responses on user-facing endpoints even though cold starts were handled. The bottleneck was downstream: too many Lambdas hammering the database simultaneously.

**Lambda concurrency controls:**

```hcl
resource "aws_lambda_function" "api" {
  ...
  reserved_concurrent_executions = 100  # hard cap — prevents DB connection storms
}
```

**Connection pooling with RDS Proxy:**

Lambda functions can't hold persistent DB connections the way a long-running server can. Without a proxy, each Lambda invocation opens and closes a connection — at scale, this exhausts the DB's connection limit.

```
Lambda invocations → RDS Proxy (connection pool) → RDS / Aurora
```

RDS Proxy maintains a warm pool of connections and multiplexes Lambda requests through them. This is the correct solution at scale — not increasing `max_connections` on the DB.

**Result:** SLA held through the next traffic spike without any manual intervention.

---

## Tech Stack Used

- **AWS:** Lambda, SQS, SNS, API Gateway, RDS, RDS Proxy, DynamoDB, EventBridge, CloudWatch, Secrets Manager
- **IaC:** Terraform
- **Languages:** Java, Python, TypeScript
- **Observability:** CloudWatch, Datadog, PagerDuty

---

## About

These patterns are distilled from production infrastructure work on enterprise-scale systems. They're intentionally language-agnostic where possible — the concepts apply whether your Lambda is Java, Python, or Node.js.

Feel free to use, adapt, or raise issues with questions.
