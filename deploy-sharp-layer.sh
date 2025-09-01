#!/bin/bash

# deploy-sharp-layer.sh - Deploy pre-built Sharp layer for AWS Lambda

set -e

echo "🔧 Deploying pre-built Sharp layer for AWS Lambda"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SHARP_VERSION="0.33.5"
LAYER_NAME="sharp-layer"
LAYER_DIR="sharp-layer"
LAYER_ZIP="sharp-layer.zip"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Check prerequisites
check_prerequisites() {
    echo "📋 Checking prerequisites..."

    if ! command -v aws &> /dev/null; then
        echo -e "${RED}❌ AWS CLI is not installed${NC}"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        echo -e "${RED}❌ curl is not installed${NC}"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}❌ AWS credentials not configured${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ All prerequisites met${NC}"
}

# Download pre-built Sharp layer
download_sharp_layer() {
    echo "📦 Downloading pre-built Sharp layer..."

    # Clean previous downloads
    rm -rf $LAYER_DIR $LAYER_ZIP

    # Create layer directory
    mkdir -p $LAYER_DIR

    # Download the pre-built Sharp layer for Node.js 18.x x64
    echo "🌐 Downloading Sharp layer for Node.js 18.x (linux-x64)..."

    # Use the pH200/sharp-layer release
    DOWNLOAD_URL="https://github.com/pH200/sharp-layer/releases/download/${SHARP_VERSION}/release-x64.zip"
    echo "${DOWNLOAD_URL}"
    # https://github.com/pH200/sharp-layer/releases/download/v0.33.5/release-x64.zip
    # https://github.com/pH200/sharp-layer/releases/download/0.33.5/release-x64.zip

    curl -L -o $LAYER_ZIP "$DOWNLOAD_URL"

    if [ ! -f $LAYER_ZIP ]; then
        echo -e "${RED}❌ Failed to download Sharp layer${NC}"
        exit 1
    fi

    # Extract to layer directory
    cd $LAYER_DIR
    unzip -q ../$LAYER_ZIP
    cd ..

    echo -e "${GREEN}✅ Sharp layer downloaded successfully${NC}"
}

# Deploy layer to AWS
deploy_layer() {
    echo "☁️ Deploying Sharp layer to AWS Lambda..."

    # Create deployment zip
    cd $LAYER_DIR
    zip -r ../$LAYER_ZIP . -q
    cd ..

    # Deploy layer
    echo "🚀 Publishing layer to AWS..."

    LAYER_VERSION=$(aws lambda publish-layer-version \
        --layer-name $LAYER_NAME \
        --zip-file fileb://$LAYER_ZIP \
        --compatible-runtimes nodejs18.x \
        --compatible-architectures x86_64 \
        --description "Pre-built Sharp layer for image processing in Lambda" \
        --region $AWS_REGION \
        --query 'Version' \
        --output text)

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Layer deployed successfully${NC}"
        echo "Layer Name: $LAYER_NAME"
        echo "Layer Version: $LAYER_VERSION"
        echo "Region: $AWS_REGION"

        # Get layer ARN with version
        LAYER_ARN=$(aws lambda get-layer-version \
            --layer-name $LAYER_NAME \
            --version-number $LAYER_VERSION \
            --region $AWS_REGION \
            --query 'LayerVersionArn' \
            --output text)

        echo "Layer ARN: $LAYER_ARN"

        # Save layer info for Terraform
        cat > layer-info.json << EOF
{
  "layer_name": "$LAYER_NAME",
  "layer_version": $LAYER_VERSION,
  "layer_arn": "$LAYER_ARN",
  "region": "$AWS_REGION"
}
EOF

        echo -e "${GREEN}✅ Layer info saved to layer-info.json${NC}"
    else
        echo -e "${RED}❌ Failed to deploy layer${NC}"
        exit 1
    fi
}

# Cleanup
cleanup() {
    echo "🧹 Cleaning up temporary files..."
    rm -rf $LAYER_DIR $LAYER_ZIP
    echo -e "${GREEN}✅ Cleanup complete${NC}"
}

# Main deployment flow
main() {
    check_prerequisites
    download_sharp_layer
    deploy_layer
    cleanup

    echo -e "${GREEN}🎉 Sharp layer deployment complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Update your Terraform configuration to use this layer"
    echo "2. Deploy your Lambda function"
    echo "3. Test image processing functionality"
    echo ""
    echo "Layer ARN for Terraform:"
    cat layer-info.json | grep layer_arn
}

# Run main function
main
