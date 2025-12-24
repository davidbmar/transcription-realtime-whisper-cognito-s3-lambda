'use strict';

/**
 * CloudDrive Actions API
 *
 * Provides endpoints for running and monitoring actions on transcript sessions.
 * Actions are pure transformations that take session data as input and produce output files.
 *
 * Endpoints:
 * - GET  /api/actions              - List available actions
 * - POST /api/actions/{actionName} - Run an action on a session
 * - GET  /api/actions/status       - Check action completion status
 */

const AWS = require('aws-sdk');
const s3 = new AWS.S3();
const lambda = new AWS.Lambda();

const BUCKET = process.env.S3_BUCKET_NAME;
const SERVICE = process.env.SERVICE_NAME || 'clouddrive-app';
const STAGE = process.env.STAGE || 'prod';

// Action definitions with their output files
const ACTIONS = {
  'ai-analysis': {
    name: 'ai-analysis',
    description: 'Generate AI analysis with action items, themes, and highlights',
    backend: 'api',
    requires: ['transcription-processed.json'],
    produces: ['transcription-ai-analysis.json', 'transcription-enhanced.json'],
    outputFile: 'transcription-ai-analysis.json'
  },
  'topics': {
    name: 'topics',
    description: 'Detect topic boundaries using semantic embeddings',
    backend: 'api',
    requires: ['transcription-processed.json'],
    produces: ['layers/layer-3-topic-segments/data.json', 'transcription-topic-segmented.json'],
    outputFile: 'layers/layer-3-topic-segments/data.json'
  },
  'transcribe': {
    name: 'transcribe',
    description: 'Transcribe audio using WhisperX (GPU - queued for batch)',
    backend: 'gpu',
    requires: [],  // Audio chunks detected by scanner
    produces: ['transcription.json', 'transcription-processed.json'],
    outputFile: 'transcription.json'
  },
  'diarize': {
    name: 'diarize',
    description: 'Identify speakers using pyannote (GPU - queued for batch)',
    backend: 'gpu',
    requires: ['transcription-processed.json'],
    produces: ['transcription-diarized.json'],
    outputFile: 'transcription-diarized.json'
  }
};

// Secure CORS helper
const getAllowedOrigin = (requestOrigin) => {
  const allowedOrigins = [
    process.env.CLOUDFRONT_URL
  ].filter(Boolean);
  return allowedOrigins.includes(requestOrigin) ? requestOrigin : allowedOrigins[0];
};

// Standard security headers
const getSecurityHeaders = (requestOrigin) => ({
  'Access-Control-Allow-Origin': getAllowedOrigin(requestOrigin),
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'X-Content-Type-Options': 'nosniff',
  'Content-Type': 'application/json'
});

// Response helper
const response = (statusCode, body, event) => ({
  statusCode,
  headers: getSecurityHeaders(event?.headers?.origin),
  body: JSON.stringify(body)
});

/**
 * GET /api/actions
 * List all available actions with their metadata.
 */
module.exports.listActions = async (event) => {
  try {
    const actions = Object.values(ACTIONS).map(action => ({
      name: action.name,
      description: action.description,
      backend: action.backend,
      requires: action.requires,
      produces: action.produces
    }));

    return response(200, { actions }, event);
  } catch (error) {
    console.error('Error listing actions:', error);
    return response(500, { error: 'Internal server error' }, event);
  }
};

/**
 * POST /api/actions/{actionName}
 * Run an action on a session.
 *
 * Request body: { sessionId: string, params?: object }
 *
 * This queues the action for processing. For now, it adds a job entry to
 * the session's metadata.json. The actual processing happens via CLI scripts
 * or could be extended to invoke processor Lambdas.
 */
module.exports.runAction = async (event) => {
  try {
    const userId = event.requestContext?.authorizer?.claims?.sub;
    if (!userId) {
      return response(401, { error: 'Unauthorized' }, event);
    }

    const actionName = event.pathParameters?.actionName;
    if (!actionName || !ACTIONS[actionName]) {
      return response(400, {
        error: `Unknown action: ${actionName}`,
        available: Object.keys(ACTIONS)
      }, event);
    }

    const body = JSON.parse(event.body || '{}');
    const { sessionId, params = {} } = body;

    if (!sessionId) {
      return response(400, { error: 'sessionId is required' }, event);
    }

    const sessionPath = `users/${userId}/audio/sessions/${sessionId}`;

    // Verify session exists
    try {
      await s3.headObject({
        Bucket: BUCKET,
        Key: `${sessionPath}/metadata.json`
      }).promise();
    } catch (err) {
      if (err.code === 'NotFound') {
        return response(404, { error: 'Session not found' }, event);
      }
      throw err;
    }

    // Check if required input files exist
    const action = ACTIONS[actionName];
    for (const requiredFile of action.requires) {
      try {
        await s3.headObject({
          Bucket: BUCKET,
          Key: `${sessionPath}/${requiredFile}`
        }).promise();
      } catch (err) {
        if (err.code === 'NotFound') {
          return response(400, {
            error: `Missing required file: ${requiredFile}`,
            hint: 'Ensure the session has been transcribed and processed first.'
          }, event);
        }
        throw err;
      }
    }

    // Update session metadata with job info
    let metadata = {};
    try {
      const metadataResult = await s3.getObject({
        Bucket: BUCKET,
        Key: `${sessionPath}/metadata.json`
      }).promise();
      metadata = JSON.parse(metadataResult.Body.toString());
    } catch (err) {
      // Metadata might not exist yet
    }

    metadata.jobs = metadata.jobs || {};
    metadata.jobs[actionName] = {
      status: 'queued',
      queuedAt: new Date().toISOString(),
      params
    };

    await s3.putObject({
      Bucket: BUCKET,
      Key: `${sessionPath}/metadata.json`,
      Body: JSON.stringify(metadata, null, 2),
      ContentType: 'application/json'
    }).promise();

    console.log(`Action queued: ${actionName} for session ${sessionPath}`);

    return response(202, {
      status: 'queued',
      action: actionName,
      sessionId,
      message: 'Action has been queued. Run the action via CLI to process, or poll /api/actions/status for completion.'
    }, event);

  } catch (error) {
    console.error('Error running action:', error);
    return response(500, { error: 'Internal server error' }, event);
  }
};

/**
 * GET /api/actions/status
 * Check completion status of an action by looking for output files.
 *
 * Query params:
 * - sessionId: Session ID
 * - action: Action name (optional - if not provided, returns status for all actions)
 */
module.exports.actionStatus = async (event) => {
  try {
    const userId = event.requestContext?.authorizer?.claims?.sub;
    if (!userId) {
      return response(401, { error: 'Unauthorized' }, event);
    }

    const sessionId = event.queryStringParameters?.sessionId;
    const actionName = event.queryStringParameters?.action;

    if (!sessionId) {
      return response(400, { error: 'sessionId is required' }, event);
    }

    const sessionPath = `users/${userId}/audio/sessions/${sessionId}`;

    // If specific action requested
    if (actionName) {
      if (!ACTIONS[actionName]) {
        return response(400, { error: `Unknown action: ${actionName}` }, event);
      }

      const action = ACTIONS[actionName];
      const outputFile = action.outputFile;

      try {
        const result = await s3.headObject({
          Bucket: BUCKET,
          Key: `${sessionPath}/${outputFile}`
        }).promise();

        return response(200, {
          action: actionName,
          status: 'completed',
          outputFile,
          lastModified: result.LastModified
        }, event);
      } catch (err) {
        if (err.code === 'NotFound') {
          // Check job status in metadata
          try {
            const metadataResult = await s3.getObject({
              Bucket: BUCKET,
              Key: `${sessionPath}/metadata.json`
            }).promise();
            const metadata = JSON.parse(metadataResult.Body.toString());
            const job = metadata.jobs?.[actionName];

            if (job) {
              return response(200, {
                action: actionName,
                status: job.status,
                queuedAt: job.queuedAt,
                startedAt: job.startedAt,
                error: job.error
              }, event);
            }
          } catch (metaErr) {
            // Metadata doesn't exist
          }

          return response(200, {
            action: actionName,
            status: 'not_started'
          }, event);
        }
        throw err;
      }
    }

    // Return status for all actions
    const statuses = {};
    for (const [name, action] of Object.entries(ACTIONS)) {
      try {
        const result = await s3.headObject({
          Bucket: BUCKET,
          Key: `${sessionPath}/${action.outputFile}`
        }).promise();

        statuses[name] = {
          status: 'completed',
          outputFile: action.outputFile,
          lastModified: result.LastModified
        };
      } catch (err) {
        if (err.code === 'NotFound') {
          statuses[name] = { status: 'not_started' };
        } else {
          statuses[name] = { status: 'error', error: err.message };
        }
      }
    }

    // Overlay with job metadata if available
    try {
      const metadataResult = await s3.getObject({
        Bucket: BUCKET,
        Key: `${sessionPath}/metadata.json`
      }).promise();
      const metadata = JSON.parse(metadataResult.Body.toString());

      for (const [name, job] of Object.entries(metadata.jobs || {})) {
        if (statuses[name] && statuses[name].status !== 'completed') {
          statuses[name] = {
            ...statuses[name],
            status: job.status,
            queuedAt: job.queuedAt,
            startedAt: job.startedAt
          };
        }
      }
    } catch (err) {
      // Metadata doesn't exist, that's ok
    }

    return response(200, { sessionId, actions: statuses }, event);

  } catch (error) {
    console.error('Error checking action status:', error);
    return response(500, { error: 'Internal server error' }, event);
  }
};
