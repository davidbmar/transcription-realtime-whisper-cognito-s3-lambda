'use strict';

/**
 * Annotations API - Layer-based annotation CRUD for transcript pipeline
 *
 * Layers 5-7 are human annotation layers:
 * - Layer 5: Junior review (paralegal, MA, tech)
 * - Layer 6: Senior review (associate, nurse, pharmacist)
 * - Layer 7: Principal approval (partner, physician, director)
 */

const AWS = require('aws-sdk');
const s3 = new AWS.S3();
const { v4: uuidv4 } = require('uuid');

// CORS helper
const getAllowedOrigin = (requestOrigin) => {
  const allowedOrigins = [process.env.CLOUDFRONT_URL].filter(Boolean);
  return allowedOrigins.includes(requestOrigin) ? requestOrigin : allowedOrigins[0];
};

const getSecurityHeaders = (requestOrigin) => ({
  'Access-Control-Allow-Origin': getAllowedOrigin(requestOrigin),
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Content-Type': 'application/json'
});

// Layer access control
const LAYER_PERMISSIONS = {
  'reviewers-junior': [5],
  'reviewers-senior': [5, 6],
  'principals': [5, 6, 7],
  'admins': [0, 1, 2, 3, 4, 5, 6, 7]
};

const getUserLayerAccess = (groups) => {
  const userGroups = groups || [];
  const accessibleLayers = new Set();

  for (const group of userGroups) {
    const layers = LAYER_PERMISSIONS[group] || [];
    layers.forEach(l => accessibleLayers.add(l));
  }

  // Default: write access to layer 1 (Speaker Chunks) and layer 5 (Annotations)
  if (accessibleLayers.size === 0) {
    accessibleLayers.add(1);  // Speaker Chunks - for chunk-split annotations
    accessibleLayers.add(5);  // Annotations - for general annotations
  }

  return Array.from(accessibleLayers);
};

/**
 * GET /api/sessions/{sessionId}/annotations
 * List all annotations for a session across all layers
 */
module.exports.listAnnotations = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const sessionId = event.pathParameters?.sessionId;

    if (!sessionId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId required' }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const queryParams = event.queryStringParameters || {};
    const layerFilter = queryParams.layer ? parseInt(queryParams.layer) : null;

    // Collect annotations from layers 1, 5-7 (Speaker Chunks + Annotation layers)
    const annotations = [];
    const layersToFetch = layerFilter ? [layerFilter] : [1, 5, 6, 7];

    for (const layer of layersToFetch) {
      const key = `users/${userId}/audio/sessions/${sessionId}/layer-${layer}-annotations/annotations.json`;

      try {
        const data = await s3.getObject({ Bucket: bucketName, Key: key }).promise();
        const layerData = JSON.parse(data.Body.toString());
        annotations.push(...(layerData.annotations || []));
      } catch (err) {
        if (err.code !== 'NoSuchKey') {
          console.error(`Error fetching layer ${layer}:`, err);
        }
        // Layer doesn't exist yet - that's fine
      }
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        sessionId,
        annotations,
        count: annotations.length
      })
    };

  } catch (error) {
    console.error('listAnnotations error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * POST /api/sessions/{sessionId}/annotations
 * Create a new annotation
 */
module.exports.createAnnotation = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const email = claims.email || 'unknown';
    const groups = claims['cognito:groups'] ? claims['cognito:groups'].split(',') : [];
    const sessionId = event.pathParameters?.sessionId;

    if (!sessionId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId required' }) };
    }

    const body = JSON.parse(event.body || '{}');
    const { layerId: rawLayerId, type, target, data } = body;

    if (!rawLayerId || !type || !target) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'layerId, type, and target required' }) };
    }

    // Convert layerId to integer for comparison (may come as string from JSON)
    const layerId = typeof rawLayerId === 'string' ? parseInt(rawLayerId, 10) : rawLayerId;

    // Check layer access
    const accessibleLayers = getUserLayerAccess(groups);
    if (!accessibleLayers.includes(layerId)) {
      return { statusCode: 403, headers, body: JSON.stringify({ error: `No write access to layer ${layerId}` }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const key = `users/${userId}/audio/sessions/${sessionId}/layer-${layerId}-annotations/annotations.json`;

    // Get existing annotations or create new file
    let layerData = { version: '1.0', layer: layerId, annotations: [] };

    try {
      const existing = await s3.getObject({ Bucket: bucketName, Key: key }).promise();
      layerData = JSON.parse(existing.Body.toString());
    } catch (err) {
      if (err.code !== 'NoSuchKey') throw err;
    }

    // Create new annotation
    const annotation = {
      id: uuidv4(),
      layerId,
      type, // tag, comment, correction, redaction, speaker-reassign, chunk-split
      target: {
        chunkId: target.chunkId,
        topicChunkId: target.topicChunkId,
        wordStart: target.wordStart,
        wordEnd: target.wordEnd,
        startTime: target.startTime,
        endTime: target.endTime,
        originalText: target.originalText
      },
      data: data || {},
      metadata: {
        createdAt: new Date().toISOString(),
        createdBy: userId,
        createdByEmail: email,
        role: body.role || 'reviewer',
        resolved: false,
        forTraining: body.forTraining !== false
      }
    };

    layerData.annotations.push(annotation);
    layerData.updatedAt = new Date().toISOString();

    // Save back to S3
    await s3.putObject({
      Bucket: bucketName,
      Key: key,
      Body: JSON.stringify(layerData, null, 2),
      ContentType: 'application/json'
    }).promise();

    console.log(`Created annotation ${annotation.id} in layer ${layerId} for session ${sessionId}`);

    return {
      statusCode: 201,
      headers,
      body: JSON.stringify({ annotation })
    };

  } catch (error) {
    console.error('createAnnotation error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * PUT /api/sessions/{sessionId}/annotations/{annotationId}
 * Update an existing annotation
 */
module.exports.updateAnnotation = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const groups = claims['cognito:groups'] ? claims['cognito:groups'].split(',') : [];
    const { sessionId, annotationId } = event.pathParameters || {};

    if (!sessionId || !annotationId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId and annotationId required' }) };
    }

    const body = JSON.parse(event.body || '{}');
    const { layerId: rawLayerId, data, resolved } = body;

    if (!rawLayerId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'layerId required' }) };
    }

    // Convert layerId to integer for comparison (may come as string from JSON)
    const layerId = typeof rawLayerId === 'string' ? parseInt(rawLayerId, 10) : rawLayerId;

    // Check layer access
    const accessibleLayers = getUserLayerAccess(groups);
    console.log('[updateAnnotation] userId:', userId, 'groups:', groups, 'accessibleLayers:', accessibleLayers, 'layerId:', layerId);
    if (!accessibleLayers.includes(layerId)) {
      console.log('[updateAnnotation] Access denied - layer', layerId, 'not in', accessibleLayers);
      return { statusCode: 403, headers, body: JSON.stringify({ error: `No write access to layer ${layerId}` }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const key = `users/${userId}/audio/sessions/${sessionId}/layer-${layerId}-annotations/annotations.json`;

    // Get existing annotations
    let layerData;
    try {
      const existing = await s3.getObject({ Bucket: bucketName, Key: key }).promise();
      layerData = JSON.parse(existing.Body.toString());
    } catch (err) {
      return { statusCode: 404, headers, body: JSON.stringify({ error: 'Annotation not found' }) };
    }

    // Find and update annotation
    const annotationIndex = layerData.annotations.findIndex(a => a.id === annotationId);
    if (annotationIndex === -1) {
      return { statusCode: 404, headers, body: JSON.stringify({ error: 'Annotation not found' }) };
    }

    const annotation = layerData.annotations[annotationIndex];

    // Update fields
    if (data) annotation.data = { ...annotation.data, ...data };
    if (resolved !== undefined) annotation.metadata.resolved = resolved;
    annotation.metadata.updatedAt = new Date().toISOString();
    annotation.metadata.updatedBy = userId;

    layerData.annotations[annotationIndex] = annotation;
    layerData.updatedAt = new Date().toISOString();

    // Save back to S3
    await s3.putObject({
      Bucket: bucketName,
      Key: key,
      Body: JSON.stringify(layerData, null, 2),
      ContentType: 'application/json'
    }).promise();

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ annotation })
    };

  } catch (error) {
    console.error('updateAnnotation error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * DELETE /api/sessions/{sessionId}/annotations/{annotationId}
 * Delete an annotation
 */
module.exports.deleteAnnotation = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const groups = claims['cognito:groups'] ? claims['cognito:groups'].split(',') : [];
    const { sessionId, annotationId } = event.pathParameters || {};

    if (!sessionId || !annotationId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId and annotationId required' }) };
    }

    const queryParams = event.queryStringParameters || {};
    const layerId = parseInt(queryParams.layerId);

    if (!layerId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'layerId query param required' }) };
    }

    // Check layer access
    const accessibleLayers = getUserLayerAccess(groups);
    if (!accessibleLayers.includes(layerId)) {
      return { statusCode: 403, headers, body: JSON.stringify({ error: `No write access to layer ${layerId}` }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const key = `users/${userId}/audio/sessions/${sessionId}/layer-${layerId}-annotations/annotations.json`;

    // Get existing annotations
    let layerData;
    try {
      const existing = await s3.getObject({ Bucket: bucketName, Key: key }).promise();
      layerData = JSON.parse(existing.Body.toString());
    } catch (err) {
      return { statusCode: 404, headers, body: JSON.stringify({ error: 'Annotation not found' }) };
    }

    // Find and remove annotation
    const annotationIndex = layerData.annotations.findIndex(a => a.id === annotationId);
    if (annotationIndex === -1) {
      return { statusCode: 404, headers, body: JSON.stringify({ error: 'Annotation not found' }) };
    }

    layerData.annotations.splice(annotationIndex, 1);
    layerData.updatedAt = new Date().toISOString();

    // Save back to S3
    await s3.putObject({
      Bucket: bucketName,
      Key: key,
      Body: JSON.stringify(layerData, null, 2),
      ContentType: 'application/json'
    }).promise();

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ deleted: true })
    };

  } catch (error) {
    console.error('deleteAnnotation error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * GET /api/sessions/{sessionId}/layers
 * Get all layer data for a session
 *
 * NEW LAYER ARCHITECTURE: Checks for manifest.json in layers/ folder first,
 * then falls back to old flat structure for backwards compatibility.
 */
module.exports.getLayers = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const sessionId = event.pathParameters?.sessionId;

    if (!sessionId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId required' }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const basePath = `users/${userId}/audio/sessions/${sessionId}`;
    const layersPath = `${basePath}/layers`;

    let manifest = null;
    const layers = {};

    // NEW LAYER ARCHITECTURE: Try to read manifest.json first
    try {
      const manifestData = await s3.getObject({
        Bucket: bucketName,
        Key: `${layersPath}/manifest.json`
      }).promise();
      manifest = JSON.parse(manifestData.Body.toString());
      console.log(`[Layers] Found manifest.json for ${sessionId}:`, Object.keys(manifest.layers || {}));
    } catch (err) {
      if (err.code !== 'NoSuchKey') console.error('Manifest error:', err);
      // No manifest - fall back to old structure
    }

    if (manifest) {
      // NEW LAYER ARCHITECTURE: Read from layers/ folder based on manifest
      for (const [layerId, layerInfo] of Object.entries(manifest.layers || {})) {
        try {
          const folderName = layerInfo.folder || `layer-${layerId}`;
          const data = await s3.getObject({
            Bucket: bucketName,
            Key: `${layersPath}/${folderName}/data.json`
          }).promise();
          layers[layerId] = {
            status: 'complete',
            data: JSON.parse(data.Body.toString()),
            name: layerInfo.name,
            type: layerInfo.type,
            locked: layerInfo.locked
          };
        } catch (err) {
          if (err.code !== 'NoSuchKey') console.error(`Layer ${layerId} error:`, err);
          layers[layerId] = {
            status: 'pending',
            name: layerInfo.name,
            type: layerInfo.type,
            locked: layerInfo.locked
          };
        }
      }

      // Also check for user annotation layers (layer-10-human-edits)
      try {
        const humanEditsData = await s3.getObject({
          Bucket: bucketName,
          Key: `${layersPath}/layer-10-human-edits/data.json`
        }).promise();
        layers['10'] = {
          status: 'complete',
          data: JSON.parse(humanEditsData.Body.toString()),
          name: 'Human Edits',
          type: 'user',
          locked: false
        };
      } catch (err) {
        if (err.code !== 'NoSuchKey') console.error('Human edits layer error:', err);
        // Layer 10 not found - that's okay
      }
    } else {
      // BACKWARDS COMPATIBILITY: Old flat file structure

      // Layer 1: Speaker Chunks (old location)
      try {
        const data = await s3.getObject({
          Bucket: bucketName,
          Key: `${basePath}/layer-1-annotations/annotations.json`
        }).promise();
        layers['1'] = { status: 'complete', data: JSON.parse(data.Body.toString()) };
      } catch (err) {
        if (err.code !== 'NoSuchKey') console.error('Layer 1 error:', err);
        layers['1'] = { status: 'pending' };
      }

      // Layer 2: Speaker chunks (legacy)
      try {
        const data = await s3.getObject({
          Bucket: bucketName,
          Key: `${basePath}/layer-2-speaker-chunks/speaker-chunks.json`
        }).promise();
        layers['2'] = { status: 'complete', data: JSON.parse(data.Body.toString()) };
      } catch (err) {
        if (err.code !== 'NoSuchKey') console.error('Layer 2 error:', err);
        layers['2'] = { status: 'pending' };
      }

      // Layer 5-7: Annotations (old structure)
      for (const layer of [5, 6, 7]) {
        try {
          const data = await s3.getObject({
            Bucket: bucketName,
            Key: `${basePath}/layer-${layer}-annotations/annotations.json`
          }).promise();
          layers[layer.toString()] = { status: 'complete', data: JSON.parse(data.Body.toString()) };
        } catch (err) {
          if (err.code !== 'NoSuchKey') console.error(`Layer ${layer} error:`, err);
          layers[layer.toString()] = { status: 'pending' };
        }
      }
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        sessionId,
        layers,
        manifest: manifest ? { version: manifest.version, nextLayerId: manifest.nextLayerId } : null
      })
    };

  } catch (error) {
    console.error('getLayers error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * POST /api/sessions/{sessionId}/layers/{layerId}/complete
 * Mark a layer as complete
 */
module.exports.completeLayer = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const email = claims.email || 'unknown';
    const groups = claims['cognito:groups'] ? claims['cognito:groups'].split(',') : [];
    const { sessionId, layerId: layerIdStr } = event.pathParameters || {};
    const layerId = parseInt(layerIdStr);

    if (!sessionId || isNaN(layerId)) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId and layerId required' }) };
    }

    // Check layer access
    const accessibleLayers = getUserLayerAccess(groups);
    if (!accessibleLayers.includes(layerId)) {
      return { statusCode: 403, headers, body: JSON.stringify({ error: `No write access to layer ${layerId}` }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const key = `users/${userId}/audio/sessions/${sessionId}/layer-${layerId}-annotations/annotations.json`;

    // Get existing annotations or create new file
    let layerData = { version: '1.0', layer: layerId, annotations: [] };

    try {
      const existing = await s3.getObject({ Bucket: bucketName, Key: key }).promise();
      layerData = JSON.parse(existing.Body.toString());
    } catch (err) {
      if (err.code !== 'NoSuchKey') throw err;
    }

    // Mark layer as complete
    layerData.status = 'complete';
    layerData.completedAt = new Date().toISOString();
    layerData.completedBy = userId;
    layerData.completedByEmail = email;

    // Save back to S3
    await s3.putObject({
      Bucket: bucketName,
      Key: key,
      Body: JSON.stringify(layerData, null, 2),
      ContentType: 'application/json'
    }).promise();

    console.log(`Layer ${layerId} marked complete for session ${sessionId} by ${email}`);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        layerId,
        status: 'complete',
        completedAt: layerData.completedAt,
        completedBy: email
      })
    };

  } catch (error) {
    console.error('completeLayer error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * GET /api/domains
 * List available domain tag libraries
 */
module.exports.listDomains = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    // Return embedded domain list (could be fetched from S3 in production)
    const domains = [
      {
        id: 'legal',
        name: 'Legal & Depositions',
        description: 'Tags for legal proceedings, depositions, hearings, and contracts'
      },
      {
        id: 'medical',
        name: 'Medical & Clinical',
        description: 'Tags for patient consultations, clinical notes, and medical dictation'
      },
      {
        id: 'general',
        name: 'General Purpose',
        description: 'Universal tags for meetings, interviews, and general transcription'
      }
    ];

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ domains, defaultDomain: 'general' })
    };

  } catch (error) {
    console.error('listDomains error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * GET /api/sessions/{sessionId}/layers/{layerId}/edits
 * Get all text edits for a specific layer
 */
module.exports.getLayerEdits = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const { sessionId, layerId } = event.pathParameters || {};

    if (!sessionId || !layerId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId and layerId required' }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const key = `users/${userId}/audio/sessions/${sessionId}/layers/layer-${layerId}-edits.json`;

    try {
      const data = await s3.getObject({ Bucket: bucketName, Key: key }).promise();
      const editsData = JSON.parse(data.Body.toString());
      return {
        statusCode: 200,
        headers,
        body: JSON.stringify(editsData)
      };
    } catch (err) {
      if (err.code === 'NoSuchKey') {
        // No edits file yet - return empty
        return {
          statusCode: 200,
          headers,
          body: JSON.stringify({
            layerId: parseInt(layerId),
            edits: {},
            version: '1.0'
          })
        };
      }
      throw err;
    }

  } catch (error) {
    console.error('getLayerEdits error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * PUT /api/sessions/{sessionId}/layers/{layerId}/edits
 * Save all text edits for a specific layer (replaces entire file)
 */
module.exports.saveLayerEdits = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const email = claims.email || 'unknown';
    const groups = claims['cognito:groups'] ? claims['cognito:groups'].split(',') : [];
    const { sessionId, layerId: layerIdStr } = event.pathParameters || {};
    const layerId = parseInt(layerIdStr);

    if (!sessionId || isNaN(layerId)) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId and layerId required' }) };
    }

    // Check layer access (only user layers 5+ can have text edits)
    if (layerId < 5) {
      return { statusCode: 403, headers, body: JSON.stringify({ error: 'Text edits only allowed on layers 5+' }) };
    }

    const accessibleLayers = getUserLayerAccess(groups);
    if (!accessibleLayers.includes(layerId)) {
      return { statusCode: 403, headers, body: JSON.stringify({ error: `No write access to layer ${layerId}` }) };
    }

    const body = JSON.parse(event.body || '{}');
    const { edits } = body;

    if (!edits || typeof edits !== 'object') {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'edits object required' }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const key = `users/${userId}/audio/sessions/${sessionId}/layers/layer-${layerId}-edits.json`;

    const editsData = {
      layerId,
      version: '1.0',
      edits,  // { "para-0": "edited text", "para-3": "another edit", ... }
      updatedAt: new Date().toISOString(),
      updatedBy: userId,
      updatedByEmail: email
    };

    await s3.putObject({
      Bucket: bucketName,
      Key: key,
      Body: JSON.stringify(editsData, null, 2),
      ContentType: 'application/json'
    }).promise();

    console.log(`Saved ${Object.keys(edits).length} text edits to layer ${layerId} for session ${sessionId}`);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        saved: true,
        layerId,
        editCount: Object.keys(edits).length
      })
    };

  } catch (error) {
    console.error('saveLayerEdits error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * GET /api/sessions/{sessionId}/all-layer-edits
 * Get text edits from all layers for a session
 */
module.exports.getAllLayerEdits = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const sessionId = event.pathParameters?.sessionId;

    if (!sessionId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId required' }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const basePath = `users/${userId}/audio/sessions/${sessionId}/layers`;

    // List all layer edit files
    const listResult = await s3.listObjectsV2({
      Bucket: bucketName,
      Prefix: `${basePath}/layer-`,
      MaxKeys: 100
    }).promise();

    const allEdits = {};

    for (const obj of listResult.Contents || []) {
      // Match layer-N-edits.json files
      const match = obj.Key.match(/layer-(\d+)-edits\.json$/);
      if (match) {
        const layerId = match[1];
        try {
          const data = await s3.getObject({ Bucket: bucketName, Key: obj.Key }).promise();
          const editsData = JSON.parse(data.Body.toString());
          allEdits[layerId] = editsData;
        } catch (err) {
          console.error(`Error reading ${obj.Key}:`, err);
        }
      }
    }

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        sessionId,
        layers: allEdits
      })
    };

  } catch (error) {
    console.error('getAllLayerEdits error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};

/**
 * POST /api/sessions/{sessionId}/export/training
 * Export annotations as training data
 */
module.exports.exportTrainingData = async (event) => {
  const headers = getSecurityHeaders(event.headers?.origin);

  try {
    const claims = event.requestContext?.authorizer?.claims || {};
    const userId = claims.sub || 'unknown';
    const sessionId = event.pathParameters?.sessionId;

    if (!sessionId) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'sessionId required' }) };
    }

    const bucketName = process.env.S3_BUCKET_NAME;
    const basePath = `users/${userId}/audio/sessions/${sessionId}`;

    // Collect all annotations marked for training
    const trainingData = {
      exportType: 'training',
      exportDate: new Date().toISOString(),
      sessionId,
      corrections: []
    };

    // Fetch annotations from layers 5-7
    for (const layer of [5, 6, 7]) {
      try {
        const data = await s3.getObject({
          Bucket: bucketName,
          Key: `${basePath}/layer-${layer}-annotations/annotations.json`
        }).promise();

        const layerData = JSON.parse(data.Body.toString());

        for (const annotation of layerData.annotations || []) {
          if (annotation.metadata?.forTraining) {
            trainingData.corrections.push({
              type: annotation.type,
              layerId: layer,
              target: annotation.target,
              data: annotation.data,
              verifiedBy: annotation.metadata.createdByEmail,
              verifiedAt: annotation.metadata.createdAt
            });
          }
        }
      } catch (err) {
        if (err.code !== 'NoSuchKey') console.error(`Layer ${layer} error:`, err);
      }
    }

    // Save export to S3
    const exportKey = `${basePath}/exports/training-data-${new Date().toISOString().split('T')[0]}.json`;
    await s3.putObject({
      Bucket: bucketName,
      Key: exportKey,
      Body: JSON.stringify(trainingData, null, 2),
      ContentType: 'application/json'
    }).promise();

    console.log(`Exported ${trainingData.corrections.length} training items to ${exportKey}`);

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({
        exported: true,
        path: exportKey,
        correctionCount: trainingData.corrections.length
      })
    };

  } catch (error) {
    console.error('exportTrainingData error:', error);
    return { statusCode: 500, headers, body: JSON.stringify({ error: error.message }) };
  }
};
