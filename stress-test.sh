#!/bin/bash

# stress-test.sh - Script to stress test the image processing pipeline
# Uploads the same image N times with randomized names to simulate load

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to generate random string
generate_random_string() {
    local length=${1:-6}
    # Use openssl for better cross-platform compatibility
    openssl rand -hex "$length" | cut -c1-"$length" | tr '[:upper:]' '[:lower:]' 2>/dev/null || {
        # Fallback method using RANDOM for better portability
        local result=""
        local chars="abcdefghijklmnopqrstuvwxyz0123456789"
        for i in $(seq 1 "$length"); do
            result="${result}${chars:$((RANDOM % ${#chars})):1}"
        done
        echo "$result"
    }
}

# Function to extract filename without extension
get_filename_without_ext() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    echo "${filename%.*}"
}

# Function to extract file extension
get_file_extension() {
    local filepath="$1"
    local filename=$(basename "$filepath")
    echo "${filename##*.}"
}

# Function to determine processing tier
get_processing_tier() {
    local size=$1
    if [ "$size" -lt 5242880 ]; then
        echo "Tier 1 (< 5MB)"
    elif [ "$size" -lt 15728640 ]; then
        echo "Tier 2 (5-15MB)"
    elif [ "$size" -le 26214400 ]; then
        echo "Tier 3 (15-25MB)"
    else
        echo "Exceeds maximum (> 25MB)"
    fi
}

# Function to format file size (cross-platform)
format_file_size() {
    local size=$1
    if [ "$size" -lt 1024 ]; then
        echo "${size}B"
    elif [ "$size" -lt 1048576 ]; then
        echo "$((size / 1024))KB"
    elif [ "$size" -lt 1073741824 ]; then
        echo "$((size / 1048576))MB"
    else
        echo "$((size / 1073741824))GB"
    fi
}

# Function to calculate estimated processing cost (rough estimates)
calculate_estimated_cost() {
    local size=$1
    local iterations=$2
    local total_size=$((size * iterations))
    
    # Rough cost estimates in USD (update based on actual AWS pricing)
    if [ "$size" -lt 5242880 ]; then
        # Tier 1: Lambda + S3 + SNS
        echo "scale=6; $iterations * 0.000001" | bc -l
    elif [ "$size" -lt 15728640 ]; then
        # Tier 2: Higher compute cost
        echo "scale=6; $iterations * 0.000003" | bc -l
    else
        # Tier 3: Highest compute cost
        echo "scale=6; $iterations * 0.000005" | bc -l
    fi
}

# Check arguments
if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
    echo -e "${RED}Usage: $0 <path-to-image> <bucket-name> <base-s3-key> <iterations> [--dry-run]${NC}"
    echo -e "Example: $0 ./images/photo.jpg my-bucket images/photo.jpg 10"
    echo -e "Example: $0 ./images/photo.jpg my-bucket images/photo.jpg 10 --dry-run"
    echo ""
    echo -e "Arguments:"
    echo -e "  path-to-image:  Local path to the image file to upload"
    echo -e "  bucket-name:    S3 bucket name where images will be uploaded"
    echo -e "  base-s3-key:    Base S3 key/path for the uploaded images"
    echo -e "  iterations:     Number of times to upload the image (N)"
    echo -e "  --dry-run:      Show what would be uploaded without actually doing it"
    echo ""
    echo -e "The script will upload the same image N times with randomized names:"
    echo -e "  photo.jpg → photo_abc123_1.jpg, photo_def456_2.jpg, etc."
    exit 1
fi

IMAGE_PATH=$1
BUCKET=$2
BASE_KEY=$3
ITERATIONS=$4
DRY_RUN=false

# Check for dry-run flag
if [ "$#" -eq 5 ] && [ "$5" = "--dry-run" ]; then
    DRY_RUN=true
fi

# Validate inputs
if [ ! -f "$IMAGE_PATH" ]; then
    echo -e "${RED}❌ Error: Image file '$IMAGE_PATH' not found${NC}"
    exit 1
fi

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
    echo -e "${RED}❌ Error: Iterations must be a positive integer${NC}"
    exit 1
fi

# Get file information
FILE_SIZE=$(stat -f%z "$IMAGE_PATH" 2>/dev/null || stat -c%s "$IMAGE_PATH" 2>/dev/null)
BASE_FILENAME=$(get_filename_without_ext "$BASE_KEY")
FILE_EXTENSION=$(get_file_extension "$BASE_KEY")
PROCESSING_TIER=$(get_processing_tier "$FILE_SIZE")

# Check if we can get SNS topic ARN
if ! SNS_TOPIC=$(tofu output -raw sns_topic_arn 2>/dev/null); then
    echo -e "${RED}❌ Error: Could not get SNS topic ARN from Terraform output${NC}"
    echo -e "Make sure you have deployed the infrastructure with 'tofu apply'"
    exit 1
fi

# Display test information
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}🧪 Dry Run - Stress Test Preview${NC}"
else
    echo -e "${BLUE}🚀 Starting Stress Test${NC}"
fi
echo -e "=================================="
echo -e "📁 Image: ${YELLOW}$IMAGE_PATH${NC}"
echo -e "🪣 Bucket: ${YELLOW}$BUCKET${NC}"
echo -e "📦 Base Key: ${YELLOW}$BASE_KEY${NC}"
echo -e "🔄 Iterations: ${YELLOW}$ITERATIONS${NC}"
echo -e "📏 File Size: ${YELLOW}$(format_file_size $FILE_SIZE)${NC} (${FILE_SIZE} bytes)"
echo -e "🎯 Processing: ${YELLOW}$PROCESSING_TIER${NC}"
if [ "$DRY_RUN" = false ]; then
    echo -e "📡 SNS Topic: ${YELLOW}$(echo $SNS_TOPIC | cut -c1-50)...${NC}"
fi
echo ""

# Ask for confirmation only if not dry run
if [ "$DRY_RUN" = false ]; then
    echo -e "${YELLOW}⚠️  This will upload $ITERATIONS files and trigger $ITERATIONS Lambda executions.${NC}"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Aborted by user${NC}"
        exit 0
    fi
fi

echo ""
if [ "$DRY_RUN" = true ]; then
    echo -e "${GREEN}🧪 Dry run - showing what would be uploaded...${NC}"
else
    echo -e "${GREEN}🔄 Starting uploads...${NC}"
fi
echo ""

# Initialize counters
SUCCESS_COUNT=0
FAILED_COUNT=0
UPLOADED_KEYS=()
START_TIME=$(date +%s)

# Main upload loop
for i in $(seq 1 "$ITERATIONS"); do
    # Generate random string and create unique key
    RANDOM_STRING=$(generate_random_string 6)
    UNIQUE_KEY="${BASE_FILENAME}_${RANDOM_STRING}_${i}.${FILE_EXTENSION}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[$i/$ITERATIONS]${NC} Would upload: ${YELLOW}$UNIQUE_KEY${NC}"
        echo -e "${GREEN}  ✅ Would upload to s3://$BUCKET/$UNIQUE_KEY${NC}"
        echo -e "${GREEN}  ✅ Would publish SNS message${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        UPLOADED_KEYS+=("$UNIQUE_KEY")
    else
        echo -e "${BLUE}[$i/$ITERATIONS]${NC} Uploading: ${YELLOW}$UNIQUE_KEY${NC}"
        
        # Upload to S3
        if aws s3 cp "$IMAGE_PATH" "s3://$BUCKET/$UNIQUE_KEY" --quiet; then
            echo -e "${GREEN}  ✅ Upload successful${NC}"
            
            # Create SNS message
            MESSAGE=$(cat <<EOF
{
  "bucket": "$BUCKET",
  "key": "$UNIQUE_KEY",
  "size": $FILE_SIZE
}
EOF
)
            
            # Create message attributes
            ATTRIBUTES=$(cat <<EOF
{
  "size": {
    "DataType": "Number",
    "StringValue": "$FILE_SIZE"
  }
}
EOF
)
            
            # Publish to SNS
            if aws sns publish \
                --topic-arn "$SNS_TOPIC" \
                --message "$MESSAGE" \
                --message-attributes "$ATTRIBUTES" \
                --output text > /dev/null; then
                echo -e "${GREEN}  ✅ SNS message published${NC}"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                UPLOADED_KEYS+=("$UNIQUE_KEY")
            else
                echo -e "${RED}  ❌ Failed to publish SNS message${NC}"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        else
            echo -e "${RED}  ❌ Upload failed${NC}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        
        # Small delay to avoid overwhelming the system
        if [ "$i" -lt "$ITERATIONS" ]; then
            sleep 0.5
        fi
    fi
    
    echo ""
done

# Calculate statistics
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_DATA_SIZE=$((FILE_SIZE * SUCCESS_COUNT))
ESTIMATED_COST=$(calculate_estimated_cost "$FILE_SIZE" "$SUCCESS_COUNT")

# Display summary
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}📊 Dry Run Summary${NC}"
else
    echo -e "${BLUE}📊 Stress Test Summary${NC}"
fi
echo -e "=================================="
echo -e "⏱️  Total Time: ${YELLOW}${TOTAL_TIME}s${NC}"
echo -e "✅ Successful: ${GREEN}$SUCCESS_COUNT${NC}/$ITERATIONS"
echo -e "❌ Failed: ${RED}$FAILED_COUNT${NC}/$ITERATIONS"
echo -e "📦 Total Data: ${YELLOW}$(format_file_size $TOTAL_DATA_SIZE)${NC}"
echo -e "💰 Est. Cost: ${YELLOW}\$${ESTIMATED_COST}${NC} (approximate)"
echo ""

if [ "$SUCCESS_COUNT" -gt 0 ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}📝 Files that would be uploaded:${NC}"
    else
        echo -e "${BLUE}📝 Uploaded Files:${NC}"
    fi
    for key in "${UPLOADED_KEYS[@]}"; do
        echo -e "  📄 s3://$BUCKET/$key"
    done
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${GREEN}🎯 This would trigger $SUCCESS_COUNT Lambda executions!${NC}"
        echo -e "Run without --dry-run to execute the actual stress test."
    else
        echo -e "${GREEN}🎯 Processing Started!${NC}"
        echo -e "Check CloudWatch logs for processing results:"
        echo -e "  aws logs tail /aws/lambda/webp-lambda-tier1 --follow"
        echo -e "  aws logs tail /aws/lambda/webp-lambda-tier2 --follow"
        echo -e "  aws logs tail /aws/lambda/webp-lambda-tier3 --follow"
    fi
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${RED}❌ No files would be processed${NC}"
    else
        echo -e "${RED}❌ No files were successfully processed${NC}"
    fi
fi

echo ""
if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}✨ Dry run completed!${NC}"
else
    echo -e "${BLUE}✨ Stress test completed!${NC}"
fi