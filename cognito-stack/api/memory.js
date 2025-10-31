'use strict';

const AWS = require('aws-sdk');
const s3 = new AWS.S3();

// Authenticated memory storage
module.exports.storeMemory = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`Storing Claude memory for user ${email} (${userId})`);

    // Parse the request body
    const memoryData = JSON.parse(event.body);
    
    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Create memory object with metadata
    const memoryObject = {
      timestamp: new Date().toISOString(),
      userId: userId,
      userEmail: email,
      source: 'claude_chrome_extension',
      memoryData: memoryData,
      conversationId: memoryData.conversationId || `conv_${Date.now()}`,
      version: '1.0.0'
    };

    // Generate S3 key
    const datePrefix = new Date().toISOString().split('T')[0]; // YYYY-MM-DD
    const timestamp = Date.now();
    const s3Key = `claude-memory/${userId}/${datePrefix}/${timestamp}.json`;

    console.log(`Storing memory to S3: ${bucketName}/${s3Key}`);

    // Store in S3
    const s3Params = {
      Bucket: bucketName,
      Key: s3Key,
      Body: JSON.stringify(memoryObject, null, 2),
      ContentType: 'application/json',
      Metadata: {
        'user-id': userId,
        'user-email': email,
        'conversation-id': memoryObject.conversationId,
        'memory-timestamp': memoryObject.timestamp
      }
    };

    const s3Response = await s3.putObject(s3Params).promise();
    
    console.log(`Memory stored successfully. ETag: ${s3Response.ETag}`);

    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Claude memory stored successfully',
        user: email,
        userId: userId,
        s3Key: s3Key,
        bucket: bucketName,
        timestamp: memoryObject.timestamp,
        conversationId: memoryObject.conversationId,
        etag: s3Response.ETag
      }, null, 2),
    };
  } catch (error) {
    console.error('Error storing Claude memory:', error);
    return {
      statusCode: 500,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// Public memory storage (for testing without authentication)
module.exports.storeMemoryPublic = async (event) => {
  try {
    console.log('Storing Claude memory (public endpoint)');

    // Parse the request body
    const memoryData = JSON.parse(event.body);
    
    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Create memory object with metadata
    const memoryObject = {
      timestamp: new Date().toISOString(),
      userId: 'chrome_extension_user',
      userEmail: 'extension@example.com',
      source: 'claude_chrome_extension_public',
      memoryData: memoryData,
      conversationId: memoryData.conversationId || `conv_${Date.now()}`,
      version: '1.0.0'
    };

    // Generate S3 key for public memories
    const datePrefix = new Date().toISOString().split('T')[0]; // YYYY-MM-DD
    const timestamp = Date.now();
    const s3Key = `claude-memory/public/${datePrefix}/${timestamp}.json`;

    console.log(`Storing public memory to S3: ${bucketName}/${s3Key}`);

    // Store in S3
    const s3Params = {
      Bucket: bucketName,
      Key: s3Key,
      Body: JSON.stringify(memoryObject, null, 2),
      ContentType: 'application/json',
      Metadata: {
        'source': 'claude-chrome-extension',
        'conversation-id': memoryObject.conversationId,
        'memory-timestamp': memoryObject.timestamp
      }
    };

    const s3Response = await s3.putObject(s3Params).promise();
    
    console.log(`Public memory stored successfully. ETag: ${s3Response.ETag}`);

    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Claude memory stored successfully (public)',
        s3Key: s3Key,
        bucket: bucketName,
        timestamp: memoryObject.timestamp,
        conversationId: memoryObject.conversationId,
        etag: s3Response.ETag
      }, null, 2),
    };
  } catch (error) {
    console.error('Error storing Claude memory (public):', error);
    return {
      statusCode: 500,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};
