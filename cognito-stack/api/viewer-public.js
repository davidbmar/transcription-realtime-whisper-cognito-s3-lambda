const AWS = require('aws-sdk');
const s3 = new AWS.S3();

// Rate limiting: Simple in-memory store (use DynamoDB/ElastiCache for production)
const requestCounts = new Map();
const RATE_LIMIT = 100; // requests per minute (viewer needs to load many chunks)
const RATE_WINDOW = 60000; // 1 minute in ms

function checkRateLimit(ip) {
  const now = Date.now();
  const userRequests = requestCounts.get(ip) || [];

  // Remove requests older than rate window
  const recentRequests = userRequests.filter(time => now - time < RATE_WINDOW);

  if (recentRequests.length >= RATE_LIMIT) {
    return false;
  }

  recentRequests.push(now);
  requestCounts.set(ip, recentRequests);
  return true;
}

/**
 * Public Viewer Endpoint - No Authentication Required
 *
 * GET /api/viewer/public/{userId}/{sessionId}/{fileName}
 *
 * Returns presigned URL for transcription file (24h expiration)
 * Implements rate limiting: 10 requests/min per IP
 */
module.exports.getPublicTranscript = async (event) => {
  console.log('Public viewer request:', JSON.stringify(event, null, 2));

  try {
    // Rate limiting by source IP
    const sourceIp = event.requestContext?.identity?.sourceIp || 'unknown';
    if (!checkRateLimit(sourceIp)) {
      return {
        statusCode: 429,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          error: 'Too many requests. Please try again later.'
        })
      };
    }

    // Extract path parameters
    const { userId, sessionId, fileName } = event.pathParameters;

    if (!userId || !sessionId || !fileName) {
      return {
        statusCode: 400,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          error: 'Missing required parameters: userId, sessionId, fileName'
        })
      };
    }

    // Validate fileName to prevent path traversal
    if (fileName.includes('..') || fileName.includes('/')) {
      return {
        statusCode: 400,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          error: 'Invalid fileName parameter'
        })
      };
    }

    // Only allow access to transcription files and metadata (not audio chunks or other files)
    const allowedFiles = [
      'transcription-chunk-',  // transcription-chunk-001.json, etc.
      'transcription.json',     // final consolidated transcription
      'metadata.json'           // session metadata (for status checking)
    ];

    const isAllowed = allowedFiles.some(prefix => fileName.startsWith(prefix) || fileName === prefix);

    if (!isAllowed) {
      return {
        statusCode: 403,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          error: 'Access denied: Only transcription files and metadata are publicly accessible'
        })
      };
    }

    const bucket = process.env.S3_BUCKET;

    // Extract date prefix from sessionId (e.g., "session_2025-11-09T20_50_33_875Z" -> "2025-11-09")
    const timestampMatch = sessionId.match(/session_(\d{4}-\d{2}-\d{2})/);
    const datePrefix = timestampMatch ? timestampMatch[1] : new Date().toISOString().split('T')[0];

    // Build S3 key with date prefix (matches audio.html session path structure)
    const key = `users/${userId}/audio/sessions/${datePrefix}-${sessionId}/${fileName}`;

    console.log(`Generating presigned URL for: s3://${bucket}/${key}`);

    // Check if file exists
    try {
      await s3.headObject({
        Bucket: bucket,
        Key: key
      }).promise();
    } catch (err) {
      if (err.code === 'NotFound') {
        return {
          statusCode: 404,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Credentials': true,
          },
          body: JSON.stringify({
            error: 'Transcription file not found'
          })
        };
      }
      throw err;
    }

    // Generate presigned URL (24 hour expiration)
    const presignedUrl = s3.getSignedUrl('getObject', {
      Bucket: bucket,
      Key: key,
      Expires: 86400 // 24 hours in seconds
    });

    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        url: presignedUrl,
        expiresIn: '24 hours'
      })
    };

  } catch (error) {
    console.error('Error generating presigned URL:', error);
    return {
      statusCode: 500,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        error: 'Internal server error',
        message: error.message
      })
    };
  }
};
