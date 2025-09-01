# Dockerfile for building Lambda function with correct Linux binaries
FROM --platform=linux/amd64 public.ecr.aws/lambda/nodejs:18

# Install zip utility
RUN yum update -y && yum install -y zip && yum clean all

# Set working directory
WORKDIR ${LAMBDA_TASK_ROOT}

# Copy package files
COPY package*.json ./

# Install dependencies (Sharp is provided by external layer)
RUN npm install --omit=dev

# Copy source code
COPY index.js ./

# Create deployment package
RUN zip -r function.zip index.js node_modules

# Output will be copied from container
CMD ["echo", "Lambda function built successfully"]
