# AWS Lambda Image Processor

A cost-efficient, performant serverless image processing pipeline that converts images to WebP format with multiple size variants.

## 🏗️ Architecture

The solution uses a tiered Lambda architecture to optimize costs and performance:

- **Tier 1**: Processes images < 5MB (1024 MB memory, 512 MB storage)
- **Tier 2**: Processes images 5-15MB (2048 MB memory, 1024 MB storage)
- **Tier 3**: Processes images 15-25MB (3008 MB memory, 2048 MB storage)

### Components

1. **S3 Bucket**: Stores original and processed images
2. **SNS Topic**: Routes image processing requests
3. **Lambda Functions**: Three tiers with different resource allocations
4. **SNS Subscriptions**: Filter messages to appropriate Lambda tier based on file size

## 📊 Resource Allocation Strategy

| Tier | File Size | Memory | Storage | Timeout | Reserved Concurrency | Use Case |
|------|-----------|--------|---------|---------|---------------------|----------|
| Tier 1 | < 5MB | 1024 MB | 512 MB | 60s | 10 | Most common images |
| Tier 2 | 5-15MB | 2048 MB | 1024 MB | 120s | 5 | High-res photos |
| Tier 3 | 15-25MB | 3008 MB | 2048 MB | 180s | 3 | Professional photos |

### Rationale

- **Memory**: Directly affects CPU allocation in Lambda. Sharp is CPU-intensive, so higher memory = faster processing
- **Storage**: Needs space for original + multiple WebP versions + Sharp binaries
- **Timeout**: Accounts for download + processing + upload time
- **Reserved Concurrency**: Prevents cost overruns while ensuring availability

## 🚀 Deployment

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- Node.js >= 18.0
- npm

### Quick Start

1. **Clone the repository and install dependencies:**
```bash
npm install
```

2. **Configure Terraform variables (optional):**
```hcl
# terraform.tfvars
project_name = "my-image-processor"
environment  = "prod"
aws_region   = "us-east-1"
webp_quality = 85
image_sizes  = [700, 1400, 2100]
```

3. **Deploy the infrastructure:**
```bash
chmod +x deploy.sh
./deploy.sh
```

### Manual Deployment

```bash
# Build Lambda function
npm ci --production --platform=linux --arch=x64
zip -r function.zip index.js node_modules

# Build Sharp layer (optional, for better cold starts)
mkdir -p sharp-layer/nodejs
cd sharp-layer/nodejs
npm init -y
npm install sharp --platform=linux --arch=x64
cd ..
zip -r ../sharp-layer.zip nodejs
cd ..

# Deploy with Terraform
terraform init
terraform plan
terraform apply
```

## 📝 Usage

### Publishing an Image for Processing

Send an SNS message with the following structure:

```json
{
  "bucket": "your-bucket-name",
  "key": "path/to/image.jpg",
  "size": 3500000
}
```

Message attributes (for routing):
```json
{
  "size": {
    "DataType": "Number",
    "StringValue": "3500000"
  }
}
```

### Using the Test Scripts

```bash
# Upload and process an image
./upload-and-process.sh /path/to/image.jpg

# Or manually trigger processing for an existing S3 image
./test-sns.sh my-bucket images/photo.jpg 3500000
```

### Output Structure

For an input image `photos/vacation.jpg`, the processor creates:
- `photos/vacation-700w.webp` (700px width)
- `photos/vacation-1400w.webp` (1400px width)
- `photos/vacation.webp` (original size in WebP)

## 🔧 Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WEBP_QUALITY` | WebP compression quality (1-100) | 85 |
| `TARGET_SIZES` | JSON array of target widths | [700, 1400] |
| `NODE_ENV` | Environment name | prod |
| `TIER` | Lambda tier identifier | (auto-set) |

### Customizing Image Sizes

Update the Terraform variable:
```hcl
variable "image_sizes" {
  default = [480, 768, 1024, 1920]
}
```

Or set via environment:
```bash
export TF_VAR_image_sizes='[480, 768, 1024, 1920]'
terraform apply
```

## 💰 Cost Optimization

### Strategies Implemented

1. **Tiered Processing**: Right-sized resources for different file sizes
2. **Reserved Concurrency**: Prevents runaway costs from concurrent executions
3. **S3 Intelligent Tiering**: Automatically moves infrequently accessed images to cheaper storage
4. **Ephemeral Storage**: Only allocate what's needed per tier
5. **WebP Format**: Reduces storage costs with smaller file sizes (~25-35% smaller than JPEG)

### Estimated Monthly Costs

Assuming 10,000 images/month:
- Tier 1 (70% of images): ~$2.50
- Tier 2 (25% of images): ~$2.00
- Tier 3 (5% of images): ~$0.80
- S3 Storage (50GB): ~$1.15
- SNS: ~$0.50
- **Total: ~$7/month**

## 🎯 Performance Optimizations

1. **Sharp Configuration**:
   - `effort: 4` - Balanced compression vs speed
   - `withoutEnlargement: true` - Skip unnecessary upscaling

2. **Memory Management**:
   - Process images in buffers, not files
   - Single read of original image
   - Garbage collection friendly

3. **S3 Optimizations**:
   - Cache-Control headers for CDN integration
   - Metadata for tracking processing

4. **Cold Start Mitigation**:
   - Optional Sharp layer for faster starts
   - Reserved concurrency for warm instances

## 📊 Monitoring

### CloudWatch Metrics

- Lambda invocations, errors, duration
- S3 bucket size and request metrics
- SNS message delivery status

### Alarms

The Terraform configuration creates alarms for:
- Lambda error rate > 10 errors in 5 minutes
- Lambda throttles
- SNS delivery failures

### Viewing Logs

```bash
# View logs for Tier 1
aws logs tail /aws/lambda/image-processor-prod-tier1 --follow

# View logs for specific time range
aws logs filter-log-events \
  --log-group-name /aws/lambda/image-processor-prod-tier1 \
  --start-time 1234567890000
```

## 🧪 Testing

### Unit Testing

```javascript
// test/index.test.js
const { handler, generateOutputKey } = require('../index');

describe('Image Processor', () => {
  test('generates correct output key', () => {
    expect(generateOutputKey('images/photo.jpg', 700))
      .toBe('images/photo-700w.webp');
  });
});
```

### Integration Testing

```bash
# Upload test image
aws s3 cp test-image.jpg s3://your-bucket/test/image.jpg

# Trigger processing
aws sns publish \
  --topic-arn arn:aws:sns:region:account:topic \
  --message '{"bucket":"your-bucket","key":"test/image.jpg","size":1000000}' \
  --message-attributes '{"size":{"DataType":"Number","StringValue":"1000000"}}'

# Verify output
aws s3 ls s3://your-bucket/test/ --recursive
```

## 🔒 Security Best Practices

1. **Least Privilege IAM**: Lambda only has access to specific S3 operations
2. **S3 Versioning**: Enabled for data protection
3. **No Public Access**: S3 bucket is private by default
4. **Input Validation**: File type and size checks
5. **Error Handling**: Graceful failures with detailed logging

## 🚨 Troubleshooting

### Common Issues

1. **Lambda Timeout**:
   - Increase timeout in Terraform configuration
   - Check if image size matches appropriate tier

2. **Sharp Installation Issues**:
   - Ensure installing for Linux platform: `npm install --platform=linux`
   - Consider using the Lambda Layer approach

3. **SNS Message Not Routing**:
   - Verify message attributes include numeric "size" field
   - Check filter policies in SNS subscriptions

4. **Out of Memory**:
   - Image might be in wrong tier
   - Very high resolution images might need Tier 3

## 📚 Additional Resources

- [Sharp Documentation](https://sharp.pixelplumbing.com/)
- [AWS Lambda Best Practices](https://docs.aws.amazon.com/lambda/latest/dg/best-practices.html)
- [WebP Image Format](https://developers.google.com/speed/webp)

## 📄 License

MIT
