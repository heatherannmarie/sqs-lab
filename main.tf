provider "aws" {
  region     = "us-east-1"
}

variable "project_name" {
  description = "A name prefix for all resources"
  type        = string
  default     = "sqs-lab"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # Specify a minimum version that supports nodejs20.x
      version = "~> 5.15" 
    }
  }
}

# S3 Buckets

resource "aws_s3_bucket" "input_bucket" {
    bucket = "${var.project_name}-input-bucket"
}

resource "aws_s3_bucket" "output_bucket" {
    bucket = "${var.project_name}-output-bucket"
}

# SNS Topic and S3 Notification

resource "aws_sns_topic" "image_event_topic" {
    name = "${var.project_name}-image-events"
}

data "aws_iam_policy_document" "s3_sns_topic_policy" {
  statement {
    effect    = "Allow"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.image_event_topic.arn]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      # This is crucial: It locks down the source to your specific input bucket.
      values   = ["${aws_s3_bucket.input_bucket.arn}"]
    }
  }
}

resource "aws_sns_topic_policy" "s3_sns_topic_policy_attachment" {
  arn    = aws_sns_topic.image_event_topic.arn
  policy = data.aws_iam_policy_document.s3_sns_topic_policy.json
  # We explicitly add a dependency to ensure the policy exists before S3 tries to validate it.
  depends_on = [
    aws_s3_bucket.input_bucket
  ]
}

resource "aws_s3_bucket_notification" "s3_notification" {
    bucket = aws_s3_bucket.input_bucket.id

    topic {
        topic_arn = aws_sns_topic.image_event_topic.arn
        events = ["s3:ObjectCreated:*"]
    }
}

# SQS Queue and Subscription

resource "aws_sqs_queue" "thumbnail_queue" {
  name = "${var.project_name}-thumbnail-queue"
  visibility_timeout_seconds = 300
}

data "aws_iam_policy_document" "sqs_policy" {
  statement {
    sid       = "AllowSNSPublish" # Add a Statement ID
    effect    = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.thumbnail_queue.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.image_event_topic.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "sqs_policy" {
  queue_url = aws_sqs_queue.thumbnail_queue.id
  policy    = data.aws_iam_policy_document.sqs_policy.json
}


resource "aws_sns_topic_subscription" "thumbnail_subscription" {
  topic_arn = aws_sns_topic.image_event_topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.thumbnail_queue.arn
}

resource "aws_sns_topic_policy" "s3_sns_topic_policy" {
  arn    = aws_sns_topic.image_event_topic.arn
  policy = data.aws_iam_policy_document.s3_sns_topic_policy.json
}

# IAM Role and Lambda Function

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    # Use standard block syntax for principals
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_exec_role" {
  name               = "${var.project_name}-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "lambda_access_policy" {
  name = "${var.project_name}-access-policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow",
        Action = ["s3:GetObject"],
        Resource = "${aws_s3_bucket.input_bucket.arn}/*"
      },
      {
        Effect = "Allow",
        Action = ["s3:PutObject"],
        Resource = "${aws_s3_bucket.output_bucket.arn}/*"
      },
      {
        Effect = "Allow",
        Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
        Resource = aws_sqs_queue.thumbnail_queue.arn
      }
    ]
  })
}

resource "aws_lambda_function" "thumbnail_generator" {
  function_name    = "${var.project_name}-generate-thumbnail"
  # You must package your Lambda code into this file:
  filename         = "lambda_function.zip"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  source_code_hash = filebase64sha256("lambda_function.zip")
  timeout          = 60
}

# Lambda Trigger

resource "aws_lambda_event_source_mapping" "thumbnail_trigger" {
  # [cite_start]5. Each SQS queue has a Lambda trigger, which processes messages in the queue. [cite: 20]
  event_source_arn = aws_sqs_queue.thumbnail_queue.arn
  function_name    = aws_lambda_function.thumbnail_generator.arn
  enabled          = true
  batch_size       = 10
}