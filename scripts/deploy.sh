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

    if ! command -v tofu &> /dev/null; then
        echo -e "${RED}❌ OpenTofu is not installed${NC}"
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
    echo "📦 Building Lambda function (Docker-free)..."

    # Clean previous builds
    rm -rf build/function-build build/function.zip
    mkdir -p build/function-build

    # Copy source files to build directory
    echo "📋 Copying source files..."
    cp -r src/index.js build/function-build/
    cp package*.json build/function-build/

    # Install production dependencies with Linux platform flags
    # Sharp requires native bindings, so we specify --os=linux --cpu=x64 --libc=glibc
    echo "📦 Installing production dependencies (including Sharp for Linux)..."
    cd build/function-build
    npm ci --omit=dev --os=linux --cpu=x64 --libc=glibc

    # Create deployment package
    echo "🗜️  Creating deployment package..."
    zip -r ../function.zip index.js node_modules -q

    # Return to root and cleanup
    cd ../..
    rm -rf build/function-build

    if [ ! -f build/function.zip ]; then
        echo -e "${RED}❌ Failed to create build/function.zip${NC}"
        exit 1
    fi

    FUNCTION_SIZE=$(du -h build/function.zip | cut -f1)
    echo -e "${GREEN}✅ Lambda function built successfully${NC}"
    echo -e "   Size: ${YELLOW}$FUNCTION_SIZE${NC}"
}

# Deploy with OpenTofu
deploy_tofu() {
    echo "🔧 Deploying infrastructure with OpenTofu..."

    cd infrastructure

    # Initialize OpenTofu
    tofu init

    # Validate configuration
    tofu validate

    # Plan deployment
    tofu plan -out=tfplan

    # Apply deployment
    echo -e "${YELLOW}⚠️  Review the plan above. Deploy? (y/n)${NC}"
    read -r response

    if [[ "$response" == "y" ]]; then
        tofu apply tfplan
        echo -e "${GREEN}✅ Infrastructure deployed successfully${NC}"
    else
        echo -e "${RED}❌ Deployment cancelled${NC}"
        cd ..
        exit 1
    fi

    cd ..
}

# Main deployment flow
main() {
    check_prerequisites
    build_lambda
    deploy_tofu

    echo -e "${GREEN}🎉 Deployment complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Upload an image to the S3 bucket"
    echo "2. Publish an SNS message with the image details"
    echo "3. Check CloudWatch logs for processing results"
    echo ""
    echo "Use the test script to send a test message:"
    echo "  ./scripts/test-sns.sh <bucket-name> <image-key> <file-size>"
}

# Run main function
main
