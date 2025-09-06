const {
  S3Client,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
} = require("@aws-sdk/client-s3");
const sharp = require("sharp");
const path = require("path");
const { promisify } = require("util");
const stream = require("stream");
const pipeline = promisify(stream.pipeline);

// Initialize AWS clients
const s3Client = new S3Client({
  region: process.env.AWS_REGION || "us-east-1",
});

// Helper function to convert stream to buffer
async function streamToBuffer(stream) {
  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

// Configuration
const DEFAULT_SIZES = [700, 1400];
const WEBP_QUALITY = parseInt(process.env.WEBP_QUALITY) || 85;
const TARGET_SIZES = process.env.TARGET_SIZES
  ? JSON.parse(process.env.TARGET_SIZES)
  : DEFAULT_SIZES;

/**
 * Lambda handler for processing images to WebP format
 */
exports.handler = async (event, context) => {
  console.log("Lambda handler started");
  console.log("Event received:", JSON.stringify(event, null, 2));
  console.log("Context:", JSON.stringify(context, null, 2));

  try {
    console.log("Parsing SNS message...");
    // Parse SNS message
    const snsMessage = JSON.parse(event.Records[0].Sns.Message);
    const { bucket, key, size } = snsMessage;
    console.log("SNS message parsed successfully:", { bucket, key, size });

    if (!bucket || !key) {
      console.error("❌ Missing required fields:", {
        bucket: !!bucket,
        key: !!key,
      });
      throw new Error("Missing required fields: bucket or key");
    }

    // Remove leading slash from key if present to avoid double slashes in S3 paths
    const sanitizedKey = key.startsWith("/") ? key.substring(1) : key;
    console.log("Key sanitization:", {
      originalKey: key,
      sanitizedKey,
      hadLeadingSlash: key.startsWith("/"),
    });

    console.log(
      `Processing image: s3://${bucket}/${sanitizedKey} (${size} bytes)`,
    );

    // Validate file extension
    console.log("Validating file extension...");
    const ext = path.extname(sanitizedKey).toLowerCase();
    console.log("File extension detected:", ext);

    if (![".jpg", ".jpeg", ".png", ".webp", ".tiff", ".avif"].includes(ext)) {
      console.error("❌ Unsupported file type:", ext);
      throw new Error(`Unsupported file type: ${ext}`);
    }
    console.log("File extension validation passed");

    // Process image
    console.log("Starting image processing...");
    const results = await processImage(bucket, sanitizedKey, TARGET_SIZES);

    console.log("Processing complete:", results);

    const response = {
      statusCode: 200,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-cache",
      },
      body: JSON.stringify({
        message: "Image processed successfully",
        results,
        remainingTime: context.getRemainingTimeInMillis(),
      }),
    };

    console.log("Returning success response:", {
      statusCode: response.statusCode,
      resultCount: results.length,
    });
    return response;
  } catch (error) {
    console.error("Error processing image:", error);
    console.error("Error details:", {
      name: error.name,
      message: error.message,
      code: error.code,
      statusCode: error.$metadata?.httpStatusCode,
      requestId: error.$metadata?.requestId,
    });

    const errorResponse = {
      statusCode: 500,
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        error: error.message,
        type: error.name,
        code: error.code,
        stack: process.env.NODE_ENV === "development" ? error.stack : undefined,
      }),
    };

    console.log("Returning error response:", {
      statusCode: errorResponse.statusCode,
      errorType: error.name,
    });
    return errorResponse;
  }
};

/**
 * Process image and create versions in both original and WebP formats
 */
async function processImage(bucket, key, sizes) {
  console.log("processImage function started");
  console.log("Input parameters:", { bucket, key, targetSizes: sizes });
  const results = [];

  try {
    // Get image metadata first to determine dimensions
    console.log("Getting S3 object metadata...");
    const headObjectCommand = new HeadObjectCommand({
      Bucket: bucket,
      Key: key,
    });
    const headObject = await s3Client.send(headObjectCommand);
    console.log(
      `S3 metadata retrieved - Original image size: ${headObject.ContentLength} bytes`,
    );
    console.log("📋 S3 object details:", {
      contentType: headObject.ContentType,
      lastModified: headObject.LastModified,
      etag: headObject.ETag,
    });

    // Download image to buffer for metadata inspection
    console.log("Downloading image from S3...");
    const getObjectCommand = new GetObjectCommand({ Bucket: bucket, Key: key });
    const originalImage = await s3Client.send(getObjectCommand);
    console.log("Image downloaded from S3");

    // Convert stream to buffer for Sharp
    console.log("Converting stream to buffer...");
    const imageBuffer = await streamToBuffer(originalImage.Body);
    console.log(`Buffer created, size: ${imageBuffer.length} bytes`);

    console.log("Analyzing image with Sharp...");
    const metadata = await sharp(imageBuffer).metadata();
    console.log(`Sharp metadata extracted:`, {
      width: metadata.width,
      height: metadata.height,
      format: metadata.format,
      space: metadata.space,
      channels: metadata.channels,
      density: metadata.density,
    });

    // Process each size in both original and WebP formats
    console.log(
      `Processing ${sizes.length} target sizes: [${sizes.join(", ")}]px`,
    );
    const formats = ['original', 'webp'];
    
    for (const targetWidth of sizes) {
      console.log(`\nProcessing size: ${targetWidth}px`);

      // Skip if target width is larger than original
      if (targetWidth >= metadata.width) {
        console.log(
          `Skipping ${targetWidth}px - larger than original (${metadata.width}px)`,
        );
        continue;
      }

      // Process both original and WebP formats
      for (const format of formats) {
        try {
          console.log(`Generating ${format} format...`);
          const outputKey = generateOutputKey(key, targetWidth, format);
          console.log(`Output key generated: ${outputKey}`);

          // Process and upload image
          console.log(`Processing and uploading ${format} image variant...`);
          await processAndUploadImage(
            imageBuffer,
            bucket,
            outputKey,
            targetWidth,
            metadata,
            format,
          );

          results.push({
            width: targetWidth,
            format: format,
            key: outputKey,
            success: true,
          });

          console.log(`Created ${targetWidth}px ${format} version: ${outputKey}`);
        } catch (error) {
          console.error(`❌ Error processing ${targetWidth}px ${format} version:`, error);
          results.push({
            width: targetWidth,
            format: format,
            error: error.message,
            success: false,
          });
        }
      }
    }
  } catch (error) {
    console.error("Error in processImage:", error);
    throw error;
  }

  console.log(`processImage completed. Generated ${results.length} variants`);
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
  format = 'webp'
) {
  console.log("processAndUploadImage started");
  console.log("Processing parameters:", {
    bucket,
    outputKey,
    targetWidth,
    format,
    originalDimensions: `${metadata.width}x${metadata.height}`,
  });

  // Calculate height to maintain aspect ratio
  const aspectRatio = metadata.height / metadata.width;
  const targetHeight = Math.round(targetWidth * aspectRatio);
  console.log("Calculated dimensions:", {
    aspectRatio: aspectRatio.toFixed(4),
    targetDimensions: `${targetWidth}x${targetHeight}`,
  });

  // Create Sharp pipeline with optimized settings
  console.log("Creating Sharp pipeline...");
  let sharpPipeline = sharp(imageBuffer, {
    failOnError: false, // Don't fail on corrupt images
    limitInputPixels: false, // Allow large images (Lambda has memory limits anyway)
  })
    .resize(targetWidth, targetHeight, {
      fit: "inside",
      withoutEnlargement: true,
      kernel: sharp.kernel.lanczos3, // Better quality for downscaling
    });

  // Apply format-specific processing
  let contentType;
  let qualitySettings = {};
  
  if (format === 'webp') {
    sharpPipeline = sharpPipeline.webp({
      quality: WEBP_QUALITY,
      effort: 4, // Balance between compression and speed
      smartSubsample: true, // Better compression
      reductionEffort: 4, // Better compression
    });
    contentType = "image/webp";
    qualitySettings = {
      quality: WEBP_QUALITY,
      effort: 4,
      smartSubsample: true,
      reductionEffort: 4,
    };
  } else if (format === 'jpeg' || format === 'jpg') {
    sharpPipeline = sharpPipeline.jpeg({
      quality: WEBP_QUALITY, // Use same quality setting
      progressive: true,
      mozjpeg: true, // Better compression
    });
    contentType = "image/jpeg";
    qualitySettings = {
      quality: WEBP_QUALITY,
      progressive: true,
      mozjpeg: true,
    };
  } else if (format === 'png') {
    sharpPipeline = sharpPipeline.png({
      compressionLevel: 6, // Balance between size and speed
      adaptiveFiltering: true,
      palette: true, // Use palette when beneficial
    });
    contentType = "image/png";
    qualitySettings = {
      compressionLevel: 6,
      adaptiveFiltering: true,
      palette: true,
    };
  } else if (format === 'original') {
    // Keep the original format based on metadata
    const originalFormat = metadata.format;
    if (originalFormat === 'jpeg') {
      sharpPipeline = sharpPipeline.jpeg({
        quality: WEBP_QUALITY,
        progressive: true,
        mozjpeg: true,
      });
      contentType = "image/jpeg";
    } else if (originalFormat === 'png') {
      sharpPipeline = sharpPipeline.png({
        compressionLevel: 6,
        adaptiveFiltering: true,
        palette: true,
      });
      contentType = "image/png";
    } else {
      // Default to original format
      contentType = `image/${originalFormat}`;
    }
    qualitySettings = { format: originalFormat };
  }

  console.log("Sharp pipeline configuration:", {
    format,
    contentType,
    ...qualitySettings,
  });

  // Convert to buffer
  console.log("Processing image with Sharp...");
  const startTime = Date.now();
  const processedBuffer = await sharpPipeline.toBuffer();
  const processingTime = Date.now() - startTime;

  console.log("Sharp processing completed:", {
    processingTimeMs: processingTime,
    originalSize: imageBuffer.length,
    processedSize: processedBuffer.length,
    compressionRatio:
      ((1 - processedBuffer.length / imageBuffer.length) * 100).toFixed(2) +
      "%",
  });

  // Upload to S3
  console.log("Uploading to S3...");
  const putObjectCommand = new PutObjectCommand({
    Bucket: bucket,
    Key: outputKey,
    Body: processedBuffer,
    ContentType: contentType,
    CacheControl: "max-age=31536000", // 1 year cache
    Metadata: {
      "original-key": outputKey,
      width: targetWidth.toString(),
      height: targetHeight.toString(),
      format: format,
      "processed-at": new Date().toISOString(),
    },
  });

  console.log("S3 upload parameters:", {
    bucket,
    key: outputKey,
    contentType,
    format,
    size: processedBuffer.length,
    cacheControl: "max-age=31536000",
  });

  const uploadStartTime = Date.now();
  await s3Client.send(putObjectCommand);
  const uploadTime = Date.now() - uploadStartTime;

  console.log(`Upload completed:`, {
    key: outputKey,
    format,
    sizeBytes: processedBuffer.length,
    uploadTimeMs: uploadTime,
  });
}

/**
 * Generate output key for resized image versions
 */
function generateOutputKey(originalKey, width, format = 'webp') {
  console.log("generateOutputKey started");
  console.log("Input parameters:", { originalKey, width, format });

  const dir = path.dirname(originalKey);
  const basename = path.basename(originalKey, path.extname(originalKey));
  const originalExt = path.extname(originalKey);

  console.log("Path components:", {
    directory: dir,
    basename: basename,
    originalExtension: originalExt,
  });

  const suffix = width === "original" ? "" : `-${width}w`;
  
  // Use the specified format, or keep original extension for 'original' format
  let extension;
  if (format === 'original') {
    extension = originalExt;
  } else if (format === 'webp') {
    extension = '.webp';
  } else {
    extension = `.${format}`;
  }
  
  const newKey = path.join(dir, `${basename}${suffix}${extension}`);

  console.log("Key construction:", {
    suffix: suffix,
    extension: extension,
    beforeRootHandling: newKey,
    startsWithDot: newKey.startsWith("."),
  });

  // Handle root directory case
  const finalKey = newKey.startsWith(".") ? newKey.substring(2) : newKey;

  console.log("generateOutputKey completed:", {
    originalKey,
    finalKey,
    format,
    transformation: `${originalKey} → ${finalKey}`,
  });

  return finalKey;
}

/**
 * Health check endpoint for testing
 */
exports.healthCheck = async () => {
  console.log("Health check endpoint called");
  console.log("Current configuration:", {
    targetSizes: TARGET_SIZES,
    webpQuality: WEBP_QUALITY,
    nodeEnv: process.env.NODE_ENV,
    region: process.env.AWS_REGION,
  });

  const response = {
    statusCode: 200,
    body: JSON.stringify({
      message: "Image processor is healthy",
      targetSizes: TARGET_SIZES,
      webpQuality: WEBP_QUALITY,
      timestamp: new Date().toISOString(),
      nodeVersion: process.version,
      platform: process.platform,
      arch: process.arch,
    }),
  };

  console.log("Health check completed successfully");
  return response;
};
