'use strict';

const AWS = require('aws-sdk');
const s3 = new AWS.S3();

const BUCKET_NAME = process.env.S3_BUCKET_NAME;

// Secure CORS helper - only allow specific origins
const getAllowedOrigin = (requestOrigin) => {
  const allowedOrigins = [
    process.env.CLOUDFRONT_URL
  ].filter(Boolean);
  return allowedOrigins.includes(requestOrigin) ? requestOrigin : allowedOrigins[0];
};

const getSecurityHeaders = (requestOrigin) => ({
  'Access-Control-Allow-Origin': getAllowedOrigin(requestOrigin),
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type, Content-Length',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'X-XSS-Protection': '1; mode=block',
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'Referrer-Policy': 'strict-origin-when-cross-origin'
});

/**
 * Queue a session for re-diarization with speaker hints
 *
 * POST /api/rediarize
 * Body: { sessionId, minSpeakers, maxSpeakers }
 *
 * This function:
 * 1. Stores speaker hints in metadata.json
 * 2. Deletes existing diarization files (so batch processor picks it up)
 * 3. Deletes cached transcription-processed.json
 *
 * The existing batch scheduler (535) or manual 515 run will process it
 * with the stored speaker hints.
 */
module.exports.queueRediarize = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) requesting re-diarization`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId, minSpeakers, maxSpeakers } = body;

    if (!sessionId) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'sessionId is required' })
      };
    }

    // Sanitize session ID
    const sanitizedSessionId = sessionId.replace(/[^a-zA-Z0-9\-_:.TZ]/g, '');
    const sessionPath = `users/${userId}/audio/sessions/${sanitizedSessionId}`;

    console.log(`Session path: ${sessionPath}`);

    // Read existing metadata (or create new)
    let metadata = {};
    const metadataKey = `${sessionPath}/metadata.json`;

    try {
      const metadataResult = await s3.getObject({
        Bucket: BUCKET_NAME,
        Key: metadataKey
      }).promise();
      metadata = JSON.parse(metadataResult.Body.toString());
      console.log(`Found existing metadata`);
    } catch (err) {
      if (err.code === 'NoSuchKey') {
        console.log(`No existing metadata, will create new`);
        metadata = { createdAt: new Date().toISOString() };
      } else {
        throw err;
      }
    }

    // Add diarization settings
    metadata.diarization = {
      minSpeakers: minSpeakers || null,
      maxSpeakers: maxSpeakers || null,
      queuedAt: new Date().toISOString(),
      queuedBy: email
    };

    // Save updated metadata
    await s3.putObject({
      Bucket: BUCKET_NAME,
      Key: metadataKey,
      Body: JSON.stringify(metadata, null, 2),
      ContentType: 'application/json'
    }).promise();

    console.log(`Saved diarization settings: min=${minSpeakers}, max=${maxSpeakers}`);

    // Delete existing diarization files so batch processor will re-process
    const filesToDelete = [
      `${sessionPath}/transcription-diarized.json`,
      `${sessionPath}/transcription-processed.json`,
      `${sessionPath}/layers/layer-1-diarization/data.json`
    ];

    let deletedCount = 0;
    for (const key of filesToDelete) {
      try {
        await s3.deleteObject({
          Bucket: BUCKET_NAME,
          Key: key
        }).promise();
        console.log(`Deleted: ${key}`);
        deletedCount++;
      } catch (err) {
        if (err.code !== 'NoSuchKey') {
          console.warn(`Failed to delete ${key}: ${err.message}`);
        }
      }
    }

    console.log(`Deleted ${deletedCount} existing files, session queued for re-diarization`);

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        status: 'queued',
        sessionId: sanitizedSessionId,
        diarization: metadata.diarization,
        message: 'Queued for re-diarization. Will process in next batch run (~1 hour) or run ./scripts/515-runpod--batch-transcribe.sh manually.'
      })
    };

  } catch (error) {
    console.error('Error queuing re-diarization:', error);
    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to queue re-diarization',
        message: error.message
      })
    };
  }
};
