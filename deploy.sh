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

    if ! command -v docker &> /dev/null; then
        echo -e "${RED}❌ Docker is not installed${NC}"
        exit 1
    fi

    # Check if Docker is running
    if ! docker info &> /dev/null; then
        echo -e "${RED}❌ Docker is not running${NC}"
        exit 1
    fi

    if ! command -v npm &> /dev/null; then
        echo -e "${YELLOW}⚠️  npm not found - will use Docker-only build${NC}"
    fi

    if ! command -v zip &> /dev/null; then
        echo -e "${RED}❌ zip is not installed${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ All prerequisites met${NC}"
}

# Build Lambda function
build_lambda() {
    echo "📦 Building Lambda function with Docker..."

    # Clean previous builds
    rm -rf node_modules function.zip

    # Build using Docker to ensure Linux compatibility
    echo "🐳 Building Lambda package in Docker container..."
    
    # Build the container for x86_64 platform
    docker build --platform linux/amd64 -t lambda-builder .
    
    # Create a temporary container and copy the zip file
    CONTAINER_ID=$(docker create lambda-builder)
    docker cp $CONTAINER_ID:/var/task/function.zip ./function.zip
    docker rm $CONTAINER_ID
    
    # Clean up the Docker image
    docker rmi lambda-builder

    if [ ! -f function.zip ]; then
        echo -e "${RED}❌ Failed to create function.zip${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ Lambda function built successfully with Docker${NC}"
}

# Deploy Sharp layer using pre-built binaries
deploy_sharp_layer() {
    echo "📦 Deploying pre-built Sharp layer..."
    
    if [ ! -f layer-info.json ]; then
        echo "🔧 Sharp layer not found, deploying..."
        ./deploy-sharp-layer.sh
    else
        echo -e "${GREEN}✅ Sharp layer already deployed${NC}"
    fi
}

# Deploy with OpenTofu
deploy_tofu() {
    echo "🔧 Deploying infrastructure with OpenTofu..."

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
        exit 1
    fi
}

# Main deployment flow
main() {
    check_prerequisites
    deploy_sharp_layer
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
    echo "  ./test-sns.sh <bucket-name> <image-key> <file-size>"
}

# Run main function
main
