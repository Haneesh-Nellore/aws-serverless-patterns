import json
import os
import boto3
import logging
from typing import Any

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ✅ Clients initialized outside handler — reused across warm invocations
sqs_client = boto3.client("sqs")
s3_client = boto3.client("s3")

OUTPUT_BUCKET = os.environ["OUTPUT_BUCKET"]
DLQ_URL = os.environ["DLQ_URL"]


def handler(event: dict, context: Any) -> dict:
    """
    SQS-Triggered Async Worker Pattern

    This Lambda is triggered by SQS messages — NOT called directly by users.
    The API Lambda enqueues jobs and returns 202 immediately.
    This worker processes them asynchronously, isolated from user-facing traffic.

    Supports partial batch failure: if some messages fail, only those are
    returned to the queue — not the entire batch.

    Architecture:
        API Lambda → SQS Queue → This Worker Lambda
                          ↓ (on failure)
                        DLQ (Dead Letter Queue)
    """
    records = event.get("Records", [])
    logger.info(f"Processing batch of {len(records)} messages")

    failed_message_ids = []

    for record in records:
        message_id = record["messageId"]
        receipt_handle = record["receiptHandle"]

        try:
            body = json.loads(record["body"])
            job_type = body.get("jobType")

            logger.info(f"Processing job: {job_type} | messageId: {message_id}")

            # Route to the right processor based on job type
            if job_type == "generate_report":
                process_report(body)
            elif job_type == "send_notification":
                process_notification(body)
            elif job_type == "data_sync":
                process_data_sync(body)
            else:
                logger.warning(f"Unknown job type: {job_type} — skipping")

            logger.info(f"Successfully processed message: {message_id}")

        except Exception as e:
            logger.error(f"Failed to process message {message_id}: {str(e)}")
            # Return this message ID as failed so SQS retries it
            # Other messages in the batch still succeed
            failed_message_ids.append({"itemIdentifier": message_id})

    # Partial batch failure response
    # SQS will only retry the failed messages, not the whole batch
    if failed_message_ids:
        logger.warning(f"{len(failed_message_ids)} messages failed — will be retried by SQS")
        return {"batchItemFailures": failed_message_ids}

    logger.info("All messages processed successfully")
    return {"batchItemFailures": []}


def process_report(job: dict) -> None:
    """Generate a report and store it in S3."""
    report_id = job.get("reportId")
    user_id = job.get("userId")

    logger.info(f"Generating report {report_id} for user {user_id}")

    # --- Your report generation logic here ---
    report_content = f"Report {report_id} generated for user {user_id}"

    # Store result in S3
    s3_client.put_object(
        Bucket=OUTPUT_BUCKET,
        Key=f"reports/{report_id}.txt",
        Body=report_content.encode("utf-8"),
        ContentType="text/plain",
    )

    logger.info(f"Report {report_id} stored in S3")


def process_notification(job: dict) -> None:
    """Send a notification (email, push, etc.)."""
    user_id = job.get("userId")
    message = job.get("message")

    logger.info(f"Sending notification to user {user_id}: {message}")
    # --- Your notification logic here (SES, SNS, etc.) ---


def process_data_sync(job: dict) -> None:
    """Sync data between systems."""
    source = job.get("source")
    destination = job.get("destination")

    logger.info(f"Syncing data from {source} to {destination}")
    # --- Your data sync logic here ---
