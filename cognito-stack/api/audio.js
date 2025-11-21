'use strict';

const AWS = require('aws-sdk');
const s3 = new AWS.S3();

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

// Generate pre-signed URL for audio chunk upload
module.exports.uploadChunk = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) requesting audio chunk upload`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId, chunkNumber, contentType, duration } = body;

    // Validate required fields
    if (!sessionId || chunkNumber === undefined) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'sessionId and chunkNumber are required' }),
      };
    }

    // Validate chunk number
    if (typeof chunkNumber !== 'number' || chunkNumber < 1) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'Invalid chunk number' }),
      };
    }

    // Sanitize session ID to prevent path traversal
    const sanitizedSessionId = sessionId.replace(/[^a-zA-Z0-9\-_]/g, '');
    if (!sanitizedSessionId) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'Invalid session ID' }),
      };
    }

    // Build S3 path - sessionId already contains timestamp
    const paddedChunkNumber = chunkNumber.toString().padStart(3, '0');

    // Build S3 key with user isolation
    const s3Key = `users/${userId}/audio/sessions/${sanitizedSessionId}/chunk-${paddedChunkNumber}.webm`;
    
    console.log(`Generating upload URL for chunk ${chunkNumber} of session ${sanitizedSessionId}`);

    // Generate pre-signed URL for upload
    const uploadUrl = s3.getSignedUrl('putObject', {
      Bucket: bucketName,
      Key: s3Key,
      Expires: 300, // 5 minutes
      ContentType: contentType || 'audio/webm'
    });

    console.log(`Generated upload URL for ${s3Key}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Upload URL generated successfully',
        uploadUrl: uploadUrl,
        s3Key: s3Key,
        sessionId: sanitizedSessionId,
        chunkNumber: chunkNumber,
        expiresIn: 300,
        maxSizeBytes: 26214400,
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error generating audio upload URL:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// Create or update session metadata
module.exports.updateSessionMetadata = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) updating session metadata`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId, metadata } = body;

    if (!sessionId || !metadata) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'sessionId and metadata are required' }),
      };
    }

    // Sanitize session ID
    const sanitizedSessionId = sessionId.replace(/[^a-zA-Z0-9\-_]/g, '');

    // Build metadata S3 key - sessionId already contains timestamp
    const metadataKey = `users/${userId}/audio/sessions/${sanitizedSessionId}/metadata.json`;
    
    // Prepare metadata object with additional fields for future consciousness features
    const fullMetadata = {
      sessionId: sanitizedSessionId,
      userId: userId,
      userEmail: email,
      createdAt: metadata.createdAt || new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      duration: metadata.duration || 0,
      chunkCount: metadata.chunkCount || 0,
      chunkDuration: metadata.chunkDuration || 5,
      status: metadata.status || 'recording',
      transcriptionStatus: 'pending',
      // Fields for future memory/consciousness features
      summary: metadata.summary || '',
      keywords: metadata.keywords || [],
      conversationContext: metadata.conversationContext || '',
      previousSession: metadata.previousSession || null,
      nextSession: null,
      ...metadata
    };

    // Upload metadata to S3
    await s3.putObject({
      Bucket: bucketName,
      Key: metadataKey,
      Body: JSON.stringify(fullMetadata, null, 2),
      ContentType: 'application/json'
    }).promise();

    console.log(`Updated metadata for session ${sanitizedSessionId}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Session metadata updated successfully',
        sessionId: sanitizedSessionId,
        metadataKey: metadataKey,
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error updating session metadata:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// List audio sessions for a user
module.exports.listSessions = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) listing audio sessions`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // List all session folders for the user with pagination
    const prefix = `users/${userId}/audio/sessions/`;

    let allCommonPrefixes = [];
    let continuationToken = null;

    do {
      const s3Params = {
        Bucket: bucketName,
        Prefix: prefix,
        Delimiter: '/',
        MaxKeys: 1000
      };

      if (continuationToken) {
        s3Params.ContinuationToken = continuationToken;
      }

      const s3Response = await s3.listObjectsV2(s3Params).promise();

      if (s3Response.CommonPrefixes) {
        allCommonPrefixes = allCommonPrefixes.concat(s3Response.CommonPrefixes);
      }

      continuationToken = s3Response.IsTruncated ? s3Response.NextContinuationToken : null;
    } while (continuationToken);

    console.log(`Found ${allCommonPrefixes.length} session folders (paginated)`);

    // Extract session folders from CommonPrefixes
    const sessions = [];
    if (allCommonPrefixes.length > 0) {
      for (const prefix of allCommonPrefixes) {
        const sessionFolder = prefix.Prefix.split('/').slice(-2)[0]; // Get folder name
        
        // Try to load metadata for each session
        try {
          const metadataKey = `${prefix.Prefix}metadata.json`;
          const metadataObj = await s3.getObject({
            Bucket: bucketName,
            Key: metadataKey
          }).promise();
          
          const metadata = JSON.parse(metadataObj.Body.toString());
          sessions.push({
            sessionId: metadata.sessionId,
            folder: sessionFolder,
            metadata: metadata
          });
        } catch (err) {
          // If no metadata, just include basic info
          sessions.push({
            sessionId: sessionFolder,
            folder: sessionFolder,
            metadata: null
          });
        }
      }
    }

    // Sort sessions by creation date (newest first)
    sessions.sort((a, b) => {
      const dateA = a.metadata?.createdAt || a.folder;
      const dateB = b.metadata?.createdAt || b.folder;
      return dateB.localeCompare(dateA);
    });

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Sessions listed successfully',
        user: email,
        userId: userId,
        sessions: sessions,
        count: sessions.length,
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error listing sessions:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// Get failed chunks for a session (for batch retry)
module.exports.getFailedChunks = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    
    // Get session ID from query parameters
    const sessionId = event.queryStringParameters?.sessionId;
    if (!sessionId) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'sessionId is required' }),
      };
    }

    // This endpoint would typically check a database or DynamoDB table
    // For MVP, we'll return expected chunks vs actual chunks in S3
    
    const bucketName = process.env.S3_BUCKET_NAME;
    const sanitizedSessionId = sessionId.replace(/[^a-zA-Z0-9\-_]/g, '');
    // sessionId already contains timestamp
    const prefix = `users/${userId}/audio/sessions/${sanitizedSessionId}/`;
    
    // List existing chunks
    const s3Response = await s3.listObjectsV2({
      Bucket: bucketName,
      Prefix: prefix
    }).promise();
    
    const existingChunks = (s3Response.Contents || [])
      .filter(obj => obj.Key.includes('chunk-'))
      .map(obj => {
        const match = obj.Key.match(/chunk-(\d+)\.webm$/);
        return match ? parseInt(match[1]) : null;
      })
      .filter(num => num !== null);
    
    // Get metadata to know expected chunks
    try {
      const metadataKey = `${prefix}metadata.json`;
      const metadataObj = await s3.getObject({
        Bucket: bucketName,
        Key: metadataKey
      }).promise();
      
      const metadata = JSON.parse(metadataObj.Body.toString());
      const expectedChunks = metadata.chunkCount || 0;
      
      // Find missing chunks
      const missingChunks = [];
      for (let i = 1; i <= expectedChunks; i++) {
        if (!existingChunks.includes(i)) {
          missingChunks.push(i);
        }
      }
      
      return {
        statusCode: 200,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          sessionId: sanitizedSessionId,
          expectedChunks: expectedChunks,
          uploadedChunks: existingChunks.sort((a, b) => a - b),
          missingChunks: missingChunks,
          timestamp: new Date().toISOString()
        }),
      };
    } catch (err) {
      // No metadata found
      return {
        statusCode: 200,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          sessionId: sanitizedSessionId,
          uploadedChunks: existingChunks.sort((a, b) => a - b),
          missingChunks: [],
          error: 'No metadata found for session',
          timestamp: new Date().toISOString()
        }),
      };
    }
  } catch (error) {
    console.error('Error checking failed chunks:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// Delete audio chunk from S3
module.exports.deleteChunk = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const email = claims.email || 'Anonymous';

    console.log(`User ${email} (${userId}) deleting audio chunk`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { sessionId, chunkNumber } = body;

    // Validate required fields
    if (!sessionId || chunkNumber === undefined) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'sessionId and chunkNumber are required' }),
      };
    }

    // Sanitize session ID
    const sanitizedSessionId = sessionId.replace(/[^a-zA-Z0-9\-_]/g, '');
    const paddedChunkNumber = chunkNumber.toString().padStart(3, '0');

    // Build S3 key with user isolation - sessionId already contains timestamp
    const s3Key = `users/${userId}/audio/sessions/${sanitizedSessionId}/chunk-${paddedChunkNumber}.webm`;

    console.log(`Deleting chunk ${chunkNumber} from ${s3Key}`);

    // Delete object from S3
    await s3.deleteObject({
      Bucket: bucketName,
      Key: s3Key
    }).promise();

    console.log(`Successfully deleted chunk ${chunkNumber} of session ${sanitizedSessionId}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Chunk deleted successfully',
        sessionId: sanitizedSessionId,
        chunkNumber: chunkNumber,
        s3Key: s3Key,
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error deleting audio chunk:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};