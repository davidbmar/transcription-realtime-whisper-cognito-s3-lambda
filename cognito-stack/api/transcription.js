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
 * Save transcription segments for a single audio chunk
 * Called in real-time as each audio chunk is uploaded
 */
module.exports.saveTranscriptionChunk = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) saving transcription chunk`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId, chunkIndex, segments } = body;

    if (!sessionId || chunkIndex === undefined || !segments) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'sessionId, chunkIndex, and segments are required' })
      };
    }

    if (!Array.isArray(segments)) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'segments must be an array' })
      };
    }

    // Build S3 key for this chunk's transcription
    const timestamp = new Date().toISOString().split('T')[0];
    const chunkKey = `users/${userId}/audio/sessions/${timestamp}-${sessionId}/transcription-chunk-${String(chunkIndex).padStart(3, '0')}.json`;

    // Calculate chunk metadata
    const chunkData = {
      chunkIndex,
      chunkStartTime: segments.length > 0 ? Math.min(...segments.map(s => s.start || 0)) : 0,
      chunkEndTime: segments.length > 0 ? Math.max(...segments.map(s => s.end || 0)) : 0,
      segments,
      segmentCount: segments.length,
      wordCount: segments.reduce((sum, seg) => sum + (seg.words?.length || 0), 0),
      uploadedAt: new Date().toISOString()
    };

    // Write chunk file to S3
    await s3.putObject({
      Bucket: BUCKET_NAME,
      Key: chunkKey,
      Body: JSON.stringify(chunkData, null, 2),
      ContentType: 'application/json',
      Metadata: {
        userId,
        sessionId,
        chunkIndex: String(chunkIndex),
        segmentCount: String(chunkData.segmentCount)
      }
    }).promise();

    console.log(`✅ Saved transcription chunk ${chunkIndex} with ${segments.length} segments to ${chunkKey}`);

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        chunkIndex,
        segmentCount: segments.length,
        s3Key: chunkKey
      })
    };

  } catch (error) {
    console.error('Error saving transcription chunk:', error);

    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to save transcription chunk',
        message: error.message
      })
    };
  }
};

/**
 * Finalize transcription session - consolidate all chunks into single file
 * Called when recording stops
 */
module.exports.finalizeTranscription = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) finalizing transcription session`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId } = body;

    if (!sessionId) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'sessionId is required' })
      };
    }

    const timestamp = new Date().toISOString().split('T')[0];
    const sessionPrefix = `users/${userId}/audio/sessions/${timestamp}-${sessionId}/`;

    // List all transcription chunk files
    const listResult = await s3.listObjectsV2({
      Bucket: BUCKET_NAME,
      Prefix: sessionPrefix,
      MaxKeys: 10000
    }).promise();

    // Filter for transcription chunk files
    const chunkFiles = listResult.Contents
      .filter(obj => obj.Key.includes('transcription-chunk-'))
      .sort((a, b) => a.Key.localeCompare(b.Key));

    console.log(`Found ${chunkFiles.length} transcription chunk files to consolidate`);

    if (chunkFiles.length === 0) {
      console.log('No transcription chunks found, skipping consolidation');
      return {
        statusCode: 200,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({
          success: true,
          message: 'No transcription data to consolidate',
          chunkCount: 0
        })
      };
    }

    // Read all chunk files
    const allSegments = [];
    let totalWordCount = 0;
    let minStartTime = Infinity;
    let maxEndTime = 0;

    for (const chunkFile of chunkFiles) {
      try {
        const chunkData = await s3.getObject({
          Bucket: BUCKET_NAME,
          Key: chunkFile.Key
        }).promise();

        const chunk = JSON.parse(chunkData.Body.toString());

        if (chunk.segments && Array.isArray(chunk.segments)) {
          allSegments.push(...chunk.segments);
          totalWordCount += chunk.wordCount || 0;

          if (chunk.chunkStartTime < minStartTime) minStartTime = chunk.chunkStartTime;
          if (chunk.chunkEndTime > maxEndTime) maxEndTime = chunk.chunkEndTime;
        }
      } catch (error) {
        console.error(`Error reading chunk file ${chunkFile.Key}:`, error);
        // Continue with other chunks
      }
    }

    // Sort segments by start time
    allSegments.sort((a, b) => (a.start || 0) - (b.start || 0));

    // Build consolidated transcription file
    const consolidatedData = {
      sessionId,
      userId,
      createdAt: new Date(Math.min(...chunkFiles.map(f => new Date(f.LastModified).getTime()))).toISOString(),
      completedAt: new Date().toISOString(),
      status: 'completed',
      chunkCount: chunkFiles.length,
      segments: allSegments,
      totalSegments: allSegments.length,
      totalDuration: maxEndTime - minStartTime,
      wordCount: totalWordCount,
      metadata: {
        transcriptionEngine: 'WhisperLive',
        hasWordTimestamps: allSegments.some(s => s.words && s.words.length > 0),
        hasParagraphBreaks: allSegments.some(s => s.paragraph_break === true),
        chunksProcessed: chunkFiles.length
      }
    };

    // Write consolidated file
    const consolidatedKey = `${sessionPrefix}transcription.json`;
    await s3.putObject({
      Bucket: BUCKET_NAME,
      Key: consolidatedKey,
      Body: JSON.stringify(consolidatedData, null, 2),
      ContentType: 'application/json',
      Metadata: {
        userId,
        sessionId,
        totalSegments: String(allSegments.length),
        totalDuration: String(consolidatedData.totalDuration)
      }
    }).promise();

    console.log(`✅ Consolidated ${allSegments.length} segments from ${chunkFiles.length} chunks into ${consolidatedKey}`);

    // Update session metadata
    const metadataKey = `${sessionPrefix}metadata.json`;
    try {
      const metadataResult = await s3.getObject({
        Bucket: BUCKET_NAME,
        Key: metadataKey
      }).promise();

      const metadata = JSON.parse(metadataResult.Body.toString());

      metadata.transcriptionStatus = 'completed';
      metadata.transcriptionSegmentCount = allSegments.length;
      metadata.transcriptionWordCount = totalWordCount;
      metadata.transcriptionUpdatedAt = new Date().toISOString();
      metadata.hasTranscription = true;
      metadata.hasWordTimestamps = consolidatedData.metadata.hasWordTimestamps;

      await s3.putObject({
        Bucket: BUCKET_NAME,
        Key: metadataKey,
        Body: JSON.stringify(metadata, null, 2),
        ContentType: 'application/json'
      }).promise();

      console.log(`✅ Updated session metadata with transcription stats`);
    } catch (error) {
      console.error('Error updating session metadata:', error);
      // Continue even if metadata update fails
    }

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        message: 'Transcription finalized successfully',
        chunksProcessed: chunkFiles.length,
        totalSegments: allSegments.length,
        totalDuration: consolidatedData.totalDuration,
        wordCount: totalWordCount
      })
    };

  } catch (error) {
    console.error('Error finalizing transcription:', error);

    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to finalize transcription',
        message: error.message
      })
    };
  }
};
