#!/bin/bash

# test-sns.sh - Script to test the image processing pipeline

set -e

# Check arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <bucket-name> <image-key> <file-size-bytes>"
    echo "Example: $0 my-bucket images/photo.jpg 3500000"
    exit 1
fi

BUCKET=$1
KEY=$2
SIZE=$3

# Get SNS topic ARN from Terraform output
SNS_TOPIC=$(tofu output -raw sns_topic_arn)

# Create SNS message
MESSAGE=$(cat <<EOF
{
  "bucket": "$BUCKET",
  "key": "$KEY",
  "size": $SIZE
}
EOF
)

# Create message attributes for filtering
ATTRIBUTES=$(cat <<EOF
{
  "size": {
    "DataType": "Number",
    "StringValue": "$SIZE"
  }
}
EOF
)

echo "📤 Publishing message to SNS topic..."
echo "Topic: $SNS_TOPIC"
echo "Message: $MESSAGE"
echo "Size: $SIZE bytes"

# Determine which tier will process this
if [ "$SIZE" -lt 5242880 ]; then
    echo "📊 This will be processed by Tier 1 (< 5MB)"
elif [ "$SIZE" -lt 15728640 ]; then
    echo "📊 This will be processed by Tier 2 (5-15MB)"
elif [ "$SIZE" -le 26214400 ]; then
    echo "📊 This will be processed by Tier 3 (15-25MB)"
else
    echo "⚠️  Warning: File size exceeds maximum supported size (25MB)"
fi

# Publish to SNS
aws sns publish \
    --topic-arn "$SNS_TOPIC" \
    --message "$MESSAGE" \
    --message-attributes "$ATTRIBUTES"

echo "✅ Message published successfully!"
echo "Check CloudWatch logs for processing results"
