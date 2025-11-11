const AWS = require('aws-sdk');
const s3 = new AWS.S3();

/**
 * Batch Transcription Lock Management
 *
 * Prevents batch transcription from running while live sessions are active.
 * Uses a simple lock file in S3 to coordinate between browser and batch processor.
 *
 * Lock file: s3://bucket/batch-lock.json
 * Format: { "locked": true, "sessionId": "session_...", "userId": "...", "timestamp": "..." }
 */

const BUCKET = process.env.S3_BUCKET;
const LOCK_KEY = 'batch-lock.json';

/**
 * Create Batch Lock
 * POST /api/batch/lock
 *
 * Called when user starts recording to prevent batch processing during live session.
 */
module.exports.createLock = async (event) => {
  console.log('Create batch lock request:', JSON.stringify(event, null, 2));

  try {
    // Extract user ID from Cognito authorizer
    const userId = event.requestContext?.authorizer?.claims?.sub;

    if (!userId) {
      return {
        statusCode: 401,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          error: 'Unauthorized - missing user ID'
        })
      };
    }

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const sessionId = body.sessionId || 'unknown';

    // Create lock file
    const lockData = {
      locked: true,
      userId,
      sessionId,
      timestamp: new Date().toISOString()
    };

    await s3.putObject({
      Bucket: BUCKET,
      Key: LOCK_KEY,
      Body: JSON.stringify(lockData),
      ContentType: 'application/json'
    }).promise();

    console.log('Batch lock created:', lockData);

    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        success: true,
        lock: lockData
      })
    };

  } catch (error) {
    console.error('Error creating batch lock:', error);
    return {
      statusCode: 500,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        error: 'Failed to create lock',
        message: error.message
      })
    };
  }
};

/**
 * Remove Batch Lock
 * POST /api/batch/unlock
 *
 * Called when user stops recording to allow batch processing to resume.
 */
module.exports.removeLock = async (event) => {
  console.log('Remove batch lock request:', JSON.stringify(event, null, 2));

  try {
    // Extract user ID from Cognito authorizer
    const userId = event.requestContext?.authorizer?.claims?.sub;

    if (!userId) {
      return {
        statusCode: 401,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({
          error: 'Unauthorized - missing user ID'
        })
      };
    }

    // Check if lock exists and belongs to this user
    try {
      const lockFile = await s3.getObject({
        Bucket: BUCKET,
        Key: LOCK_KEY
      }).promise();

      const lockData = JSON.parse(lockFile.Body.toString());

      if (lockData.userId !== userId) {
        return {
          statusCode: 403,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Credentials': true,
          },
          body: JSON.stringify({
            error: 'Lock belongs to different user',
            lockUserId: lockData.userId
          })
        };
      }
    } catch (err) {
      if (err.code === 'NoSuchKey') {
        // Lock doesn't exist - that's fine
        console.log('Lock file does not exist, nothing to remove');
      } else {
        throw err;
      }
    }

    // Delete lock file
    await s3.deleteObject({
      Bucket: BUCKET,
      Key: LOCK_KEY
    }).promise();

    console.log('Batch lock removed for user:', userId);

    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        success: true,
        message: 'Lock removed'
      })
    };

  } catch (error) {
    console.error('Error removing batch lock:', error);
    return {
      statusCode: 500,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        error: 'Failed to remove lock',
        message: error.message
      })
    };
  }
};

/**
 * Check Batch Lock Status
 * GET /api/batch/lock-status
 *
 * Allows batch processor to check if transcription should run.
 * Public endpoint (no auth) - batch script calls this.
 */
module.exports.checkLock = async (event) => {
  console.log('Check batch lock request');

  try {
    // Try to get lock file
    try {
      const lockFile = await s3.getObject({
        Bucket: BUCKET,
        Key: LOCK_KEY
      }).promise();

      const lockData = JSON.parse(lockFile.Body.toString());

      // Check if lock is stale (older than 30 minutes)
      const lockAge = Date.now() - new Date(lockData.timestamp).getTime();
      const LOCK_TIMEOUT = 30 * 60 * 1000; // 30 minutes

      if (lockAge > LOCK_TIMEOUT) {
        console.log('Lock is stale, removing it');
        await s3.deleteObject({
          Bucket: BUCKET,
          Key: LOCK_KEY
        }).promise();

        return {
          statusCode: 200,
          headers: {
            'Access-Control-Allow-Origin': '*',
          },
          body: JSON.stringify({
            locked: false,
            message: 'Stale lock removed'
          })
        };
      }

      return {
        statusCode: 200,
        headers: {
          'Access-Control-Allow-Origin': '*',
        },
        body: JSON.stringify({
          locked: true,
          sessionId: lockData.sessionId,
          timestamp: lockData.timestamp,
          ageMinutes: Math.floor(lockAge / 60000)
        })
      };

    } catch (err) {
      if (err.code === 'NoSuchKey') {
        // No lock file = not locked
        return {
          statusCode: 200,
          headers: {
            'Access-Control-Allow-Origin': '*',
          },
          body: JSON.stringify({
            locked: false
          })
        };
      }
      throw err;
    }

  } catch (error) {
    console.error('Error checking batch lock:', error);
    return {
      statusCode: 500,
      headers: {
        'Access-Control-Allow-Origin': '*',
      },
      body: JSON.stringify({
        error: 'Failed to check lock',
        message: error.message
      })
    };
  }
};
