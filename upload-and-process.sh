#!/bin/bash

# upload-and-process.sh - Helper script to upload an image and trigger processing

set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path-to-image>"
    echo "Example: $0 /path/to/photo.jpg"
    exit 1
fi

IMAGE_PATH=$1
BUCKET=$(terraform output -raw bucket_name)
KEY="images/$(basename $IMAGE_PATH)"
SIZE=$(stat -f%z "$IMAGE_PATH" 2>/dev/null || stat -c%s "$IMAGE_PATH" 2>/dev/null)

echo "📤 Uploading image to S3..."
aws s3 cp "$IMAGE_PATH" "s3://$BUCKET/$KEY"

echo "✅ Image uploaded successfully"
echo "Triggering processing..."

./test-sns.sh "$BUCKET" "$KEY" "$SIZE"
