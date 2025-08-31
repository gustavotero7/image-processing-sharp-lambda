#!/bin/bash

# deploy.sh - Deployment script for the image processor Lambda

set -e

echo "🚀 Starting deployment of Image Processor Lambda"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check prerequisites
check_prerequisites() {
    echo "📋 Checking prerequisites..."

    if ! command -v terraform &> /dev/null; then
        echo -e "${RED}❌ Terraform is not installed${NC}"
        exit 1
    fi

    if ! command -v npm &> /dev/null; then
        echo -e "${RED}❌ npm is not installed${NC}"
        exit 1
    fi

    if ! command -v zip &> /dev/null; then
        echo -e "${RED}❌ zip is not installed${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ All prerequisites met${NC}"
}

# Build Lambda function
build_lambda() {
    echo "📦 Building Lambda function..."

    # Clean previous builds
    rm -rf node_modules function.zip

    # Install production dependencies
    npm ci --production --platform=linux --arch=x64

    # Create deployment package
    zip -r function.zip index.js node_modules

    echo -e "${GREEN}✅ Lambda function built successfully${NC}"
}

# Build Sharp layer (optional, for better cold starts)
build_sharp_layer() {
    echo "📦 Building Sharp layer..."

    mkdir -p sharp-layer/nodejs
    cd sharp-layer/nodejs

    # Create package.json for layer
    cat > package.json <<EOF
{
  "name": "sharp-layer",
  "version": "1.0.0",
  "dependencies": {
    "sharp": "^0.33.0"
  }
}
EOF

    # Install Sharp for Linux
    npm install --platform=linux --arch=x64

    cd ..
    zip -r ../sharp-layer.zip nodejs
    cd ..
    rm -rf sharp-layer

    echo -e "${GREEN}✅ Sharp layer built successfully${NC}"
}

# Deploy with Terraform
deploy_terraform() {
    echo "🔧 Deploying infrastructure with Terraform..."

    # Initialize Terraform
    terraform init

    # Validate configuration
    terraform validate

    # Plan deployment
    terraform plan -out=tfplan

    # Apply deployment
    echo -e "${YELLOW}⚠️  Review the plan above. Deploy? (y/n)${NC}"
    read -r response

    if [[ "$response" == "y" ]]; then
        terraform apply tfplan
        echo -e "${GREEN}✅ Infrastructure deployed successfully${NC}"
    else
        echo -e "${RED}❌ Deployment cancelled${NC}"
        exit 1
    fi
}

# Main deployment flow
main() {
    check_prerequisites
    build_lambda
    build_sharp_layer
    deploy_terraform

    echo -e "${GREEN}🎉 Deployment complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Upload an image to the S3 bucket"
    echo "2. Publish an SNS message with the image details"
    echo "3. Check CloudWatch logs for processing results"
    echo ""
    echo "Use the test script to send a test message:"
    echo "  ./test-sns.sh <bucket-name> <image-key> <file-size>"
}

# Run main function
main
