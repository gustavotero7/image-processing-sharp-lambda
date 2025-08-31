const AWS = require("aws-sdk");
const sharp = require("sharp");
const path = require("path");
const { promisify } = require("util");
const stream = require("stream");
const pipeline = promisify(stream.pipeline);

// Initialize AWS clients
const s3 = new AWS.S3();

// Configuration
const DEFAULT_SIZES = [700, 1400];
const WEBP_QUALITY = parseInt(process.env.WEBP_QUALITY) || 85;
const TARGET_SIZES = process.env.TARGET_SIZES
  ? JSON.parse(process.env.TARGET_SIZES)
  : DEFAULT_SIZES;

/**
 * Lambda handler for processing images to WebP format
 */
exports.handler = async (event) => {
  console.log("Event received:", JSON.stringify(event, null, 2));

  try {
    // Parse SNS message
    const snsMessage = JSON.parse(event.Records[0].Sns.Message);
    const { bucket, key, size } = snsMessage;

    if (!bucket || !key) {
      throw new Error("Missing required fields: bucket or key");
    }

    console.log(`Processing image: s3://${bucket}/${key} (${size} bytes)`);

    // Validate file extension
    const ext = path.extname(key).toLowerCase();
    if (![".jpg", ".jpeg", ".png"].includes(ext)) {
      throw new Error(`Unsupported file type: ${ext}`);
    }

    // Process image
    const results = await processImage(bucket, key, TARGET_SIZES);

    console.log("Processing complete:", results);
    return {
      statusCode: 200,
      body: JSON.stringify({
        message: "Image processed successfully",
        results,
      }),
    };
  } catch (error) {
    console.error("Error processing image:", error);
    throw error;
  }
};

/**
 * Process image and create WebP versions
 */
async function processImage(bucket, key, sizes) {
  const results = [];

  try {
    // Get image metadata first to determine dimensions
    const headObject = await s3
      .headObject({ Bucket: bucket, Key: key })
      .promise();
    console.log(`Original image size: ${headObject.ContentLength} bytes`);

    // Download image to buffer for metadata inspection
    const originalImage = await s3
      .getObject({ Bucket: bucket, Key: key })
      .promise();
    const metadata = await sharp(originalImage.Body).metadata();

    console.log(`Original dimensions: ${metadata.width}x${metadata.height}`);

    // Process each size
    for (const targetWidth of sizes) {
      // Skip if target width is larger than original
      if (targetWidth >= metadata.width) {
        console.log(
          `Skipping ${targetWidth}px - larger than original (${metadata.width}px)`,
        );
        continue;
      }

      try {
        const outputKey = generateOutputKey(key, targetWidth);

        // Process and upload image
        await processAndUploadImage(
          originalImage.Body,
          bucket,
          outputKey,
          targetWidth,
          metadata,
        );

        results.push({
          width: targetWidth,
          key: outputKey,
          success: true,
        });

        console.log(`Created ${targetWidth}px version: ${outputKey}`);
      } catch (error) {
        console.error(`Error processing ${targetWidth}px version:`, error);
        results.push({
          width: targetWidth,
          error: error.message,
          success: false,
        });
      }
    }

    // Always create a WebP version at original size
    const originalWebpKey = generateOutputKey(key, "original");
    await processAndUploadImage(
      originalImage.Body,
      bucket,
      originalWebpKey,
      metadata.width,
      metadata,
    );

    results.push({
      width: metadata.width,
      key: originalWebpKey,
      original: true,
      success: true,
    });
  } catch (error) {
    console.error("Error in processImage:", error);
    throw error;
  }

  return results;
}

/**
 * Process and upload a single image variant
 */
async function processAndUploadImage(
  imageBuffer,
  bucket,
  outputKey,
  targetWidth,
  metadata,
) {
  // Calculate height to maintain aspect ratio
  const aspectRatio = metadata.height / metadata.width;
  const targetHeight = Math.round(targetWidth * aspectRatio);

  // Create Sharp pipeline
  const sharpPipeline = sharp(imageBuffer)
    .resize(targetWidth, targetHeight, {
      fit: "inside",
      withoutEnlargement: true,
    })
    .webp({
      quality: WEBP_QUALITY,
      effort: 4, // Balance between compression and speed
    });

  // Convert to buffer
  const processedBuffer = await sharpPipeline.toBuffer();

  // Upload to S3
  const uploadParams = {
    Bucket: bucket,
    Key: outputKey,
    Body: processedBuffer,
    ContentType: "image/webp",
    CacheControl: "max-age=31536000", // 1 year cache
    Metadata: {
      "original-key": outputKey,
      width: targetWidth.toString(),
      height: targetHeight.toString(),
      "processed-at": new Date().toISOString(),
    },
  };

  await s3.putObject(uploadParams).promise();

  console.log(`Uploaded: ${outputKey} (${processedBuffer.length} bytes)`);
}

/**
 * Generate output key for WebP version
 */
function generateOutputKey(originalKey, width) {
  const dir = path.dirname(originalKey);
  const basename = path.basename(originalKey, path.extname(originalKey));

  const suffix = width === "original" ? "" : `-${width}w`;
  const newKey = path.join(dir, `${basename}${suffix}.webp`);

  // Handle root directory case
  return newKey.startsWith(".") ? newKey.substring(2) : newKey;
}

/**
 * Health check endpoint for testing
 */
exports.healthCheck = async () => {
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: "Image processor is healthy",
      targetSizes: TARGET_SIZES,
      webpQuality: WEBP_QUALITY,
    }),
  };
};
