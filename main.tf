# Variables
variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "image-processor"
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "webp_quality" {
  description = "WebP compression quality (1-100)"
  type        = number
  default     = 85
}

variable "image_sizes" {
  description = "Target image widths for WebP versions"
  type        = list(number)
  default     = [700, 1400]
}

# Local variables
locals {
  bucket_name = "${var.project_name}-${var.environment}-images"

  # Lambda tier configurations
  lambda_tiers = {
    tier1 = {
      memory_size          = 1024
      ephemeral_storage    = 512
      timeout              = 60
      max_file_size        = 5242880  # 5MB in bytes
      reserved_concurrent  = -1  # No reserved concurrency (use account pool)
    }
    tier2 = {
      memory_size          = 2048
      ephemeral_storage    = 1024
      timeout              = 120
      max_file_size        = 15728640 # 15MB in bytes
      reserved_concurrent  = -1  # No reserved concurrency (use account pool)
    }
    tier3 = {
      memory_size          = 3008
      ephemeral_storage    = 2048
      timeout              = 180
      max_file_size        = 26214400 # 25MB in bytes
      reserved_concurrent  = -1  # No reserved concurrency (use account pool)
    }
  }
}

# S3 Bucket for images
resource "aws_s3_bucket" "images" {
  bucket = local.bucket_name

  tags = {
    Name        = local.bucket_name
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    id     = "delete-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

# SNS Topic
resource "aws_sns_topic" "image_processing" {
  name = "${var.project_name}-${var.environment}-image-processing"

  tags = {
    Name        = "${var.project_name}-image-processing"
    Environment = var.environment
    Project     = var.project_name
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-lambda-role"
    Environment = var.environment
    Project     = var.project_name
  }
}

# IAM Policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:HeadObject"
        ]
        Resource = "${aws_s3_bucket.images.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Subscribe",
          "sns:Receive"
        ]
        Resource = aws_sns_topic.image_processing.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# Sharp Layer - External pre-built layer
# Layer must be deployed separately using ./deploy-sharp-layer.sh
data "local_file" "layer_info" {
  filename = "${path.module}/layer-info.json"
}

locals {
  layer_info = jsondecode(data.local_file.layer_info.content)
}

# Lambda Functions (3 tiers)
resource "aws_lambda_function" "image_processor" {
  for_each = local.lambda_tiers

  filename         = "function.zip"
  source_code_hash = filebase64sha256("function.zip")
  function_name    = "${var.project_name}-${var.environment}-${each.key}"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = each.value.timeout
  memory_size     = each.value.memory_size

  ephemeral_storage {
    size = each.value.ephemeral_storage
  }

  reserved_concurrent_executions = each.value.reserved_concurrent

  # Use pre-built Sharp layer
  layers = [local.layer_info.layer_arn]

  environment {
    variables = {
      WEBP_QUALITY  = var.webp_quality
      TARGET_SIZES  = jsonencode(var.image_sizes)
      NODE_ENV      = var.environment
      TIER          = each.key
    }
  }

  tags = {
    Name        = "${var.project_name}-${each.key}"
    Environment = var.environment
    Project     = var.project_name
    Tier        = each.key
  }
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "lambda_logs" {
  for_each = local.lambda_tiers

  name              = "/aws/lambda/${aws_lambda_function.image_processor[each.key].function_name}"
  retention_in_days = 7

  tags = {
    Name        = "${var.project_name}-${each.key}-logs"
    Environment = var.environment
    Project     = var.project_name
    Tier        = each.key
  }
}

# Lambda Permissions for SNS
resource "aws_lambda_permission" "sns_invoke" {
  for_each = local.lambda_tiers

  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_processor[each.key].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.image_processing.arn
}

# SNS Subscriptions with Filtering
resource "aws_sns_topic_subscription" "lambda_tier1" {
  topic_arn = aws_sns_topic.image_processing.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.image_processor["tier1"].arn

  filter_policy = jsonencode({
    size = [
      {
        numeric = ["<", local.lambda_tiers.tier1.max_file_size]
      }
    ]
  })

  depends_on = [aws_lambda_permission.sns_invoke["tier1"]]
}

resource "aws_sns_topic_subscription" "lambda_tier2" {
  topic_arn = aws_sns_topic.image_processing.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.image_processor["tier2"].arn

  filter_policy = jsonencode({
    size = [
      {
        numeric = [">=", local.lambda_tiers.tier1.max_file_size, "<", local.lambda_tiers.tier2.max_file_size]
      }
    ]
  })

  depends_on = [aws_lambda_permission.sns_invoke["tier2"]]
}

resource "aws_sns_topic_subscription" "lambda_tier3" {
  topic_arn = aws_sns_topic.image_processing.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.image_processor["tier3"].arn

  filter_policy = jsonencode({
    size = [
      {
        numeric = [">=", local.lambda_tiers.tier2.max_file_size, "<=", local.lambda_tiers.tier3.max_file_size]
      }
    ]
  })

  depends_on = [aws_lambda_permission.sns_invoke["tier3"]]
}

# CloudWatch Alarms for Lambda Errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.lambda_tiers

  alarm_name          = "${var.project_name}-${each.key}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "10"
  alarm_description   = "This metric monitors lambda errors"

  dimensions = {
    FunctionName = aws_lambda_function.image_processor[each.key].function_name
  }

  tags = {
    Name        = "${var.project_name}-${each.key}-error-alarm"
    Environment = var.environment
    Project     = var.project_name
    Tier        = each.key
  }
}

# Outputs
output "bucket_name" {
  value       = aws_s3_bucket.images.id
  description = "Name of the S3 bucket for images"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.image_processing.arn
  description = "ARN of the SNS topic for image processing"
}

output "lambda_function_arns" {
  value = {
    for k, v in aws_lambda_function.image_processor : k => v.arn
  }
  description = "ARNs of the Lambda functions by tier"
}

output "lambda_function_names" {
  value = {
    for k, v in aws_lambda_function.image_processor : k => v.function_name
  }
  description = "Names of the Lambda functions by tier"
}
