'use strict';

const { google } = require('googleapis');
const AWS = require('aws-sdk');

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

// Initialize Google Docs API client
const getDocsClient = () => {
  // Get credentials from environment variable (base64 encoded JSON)
  const credsBase64 = process.env.GOOGLE_CREDENTIALS_BASE64;
  if (!credsBase64) {
    throw new Error('GOOGLE_CREDENTIALS_BASE64 environment variable not set');
  }

  const credsJson = Buffer.from(credsBase64, 'base64').toString('utf-8');
  const credentials = JSON.parse(credsJson);

  const auth = new google.auth.GoogleAuth({
    credentials: credentials,
    scopes: ['https://www.googleapis.com/auth/documents'],
  });

  return google.docs({ version: 'v1', auth });
};

// Get document end index
const getDocumentEnd = async (docs, documentId) => {
  const doc = await docs.documents.get({ documentId });
  const content = doc.data.body.content;
  return content[content.length - 1].endIndex || 1;
};

// Initialize document with live transcription section (Two-Section Model)
// Section 1: Finalized transcription (permanent, grows upward)
// Section 2: Live section (updates in real-time, gets cleared when finalized)
module.exports.initializeLiveSection = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) initializing Google Docs live transcription`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { documentId } = body;

    if (!documentId) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'documentId is required' })
      };
    }

    const docs = getDocsClient();

    // Get current document end
    const endIndex = await getDocumentEnd(docs, documentId);

    // Add header with two sections
    const timestamp = new Date().toLocaleString('en-US', {
      timeZone: 'America/New_York',
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });

    const headerText = `\n\n─────────────────────────────────────\n🎤 Live Transcription Started: ${timestamp}\n─────────────────────────────────────\n\n`;

    const requests = [
      {
        insertText: {
          text: headerText,
          location: { index: endIndex - 1 }
        }
      }
    ];

    await docs.documents.batchUpdate({
      documentId,
      requestBody: { requests }
    });

    // Add italic placeholder for live section
    const liveStartIndex = endIndex - 1 + headerText.length;
    await docs.documents.batchUpdate({
      documentId,
      requestBody: {
        requests: [
          {
            insertText: {
              text: '[Listening...]\n',
              location: { index: liveStartIndex }
            }
          },
          {
            updateTextStyle: {
              textStyle: {
                italic: true
              },
              range: {
                startIndex: liveStartIndex,
                endIndex: liveStartIndex + '[Listening...]\n'.length
              },
              fields: 'italic'
            }
          }
        ]
      }
    });

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        liveStartIndex,  // Where live text updates happen
        documentUrl: `https://docs.google.com/document/d/${documentId}/edit`
      })
    };

  } catch (error) {
    console.error('Error initializing live section:', error);

    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to initialize live section',
        message: error.message
      })
    };
  }
};

// Update live transcription - simple two-section model
// Just update the live section, finalization happens separately
module.exports.updateLiveTranscription = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) updating Google Docs live transcription`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { documentId, liveStartIndex, text } = body;

    if (!documentId || liveStartIndex === undefined || !text) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'documentId, liveStartIndex, and text are required' })
      };
    }

    const docs = getDocsClient();

    // Get current document
    const doc = await docs.documents.get({ documentId });
    const docEnd = doc.data.body.content[doc.data.body.content.length - 1].endIndex;

    // Use the liveStartIndex passed from frontend
    // Delete everything from liveStartIndex to end, then insert new italic text
    const newText = text + '\n';
    const requests = [
      // Delete current live section content
      {
        deleteContentRange: {
          range: {
            startIndex: liveStartIndex,
            endIndex: docEnd - 1
          }
        }
      },
      // Insert new live text
      {
        insertText: {
          text: newText,
          location: { index: liveStartIndex }
        }
      },
      // Make it italic
      {
        updateTextStyle: {
          textStyle: {
            italic: true
          },
          range: {
            startIndex: liveStartIndex,
            endIndex: liveStartIndex + newText.length
          },
          fields: 'italic'
        }
      }
    ];

    await docs.documents.batchUpdate({
      documentId,
      requestBody: { requests }
    });

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({ success: true })
    };

  } catch (error) {
    console.error('Error updating live transcription:', error);

    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to update live transcription',
        message: error.message
      })
    };
  }
};

// Finalize a segment - move from live section to permanent section
// This gets called when a segment is finalized (is_final: true)
module.exports.finalizeTranscription = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) finalizing segment to Google Docs`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { documentId, liveStartIndex, text } = body;

    if (!documentId || liveStartIndex === undefined || !text) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'documentId, liveStartIndex, and text are required' })
      };
    }

    const docs = getDocsClient();

    // Strategy: Two-phase approach to avoid race conditions
    // Phase 1: Insert finalized text BEFORE the live section
    // Phase 2: Clear and reset the live section as italic

    // Phase 1: Insert finalized text at liveStartIndex position
    await docs.documents.batchUpdate({
      documentId,
      requestBody: {
        requests: [{
          insertText: {
            text: text + ' ',
            location: { index: liveStartIndex }
          }
        }]
      }
    });

    // Phase 2: Fetch fresh document state and reset live section
    const doc = await docs.documents.get({ documentId });
    const docEnd = doc.data.body.content[doc.data.body.content.length - 1].endIndex;

    // Calculate new live start position (shifted by the length of finalized text)
    const finalizedLength = (text + ' ').length;
    const newLiveStart = liveStartIndex + finalizedLength;

    const resetText = '[Listening...]\n';
    const requests = [];

    // Delete current live section
    if (docEnd - 1 > newLiveStart) {
      requests.push({
        deleteContentRange: {
          range: {
            startIndex: newLiveStart,
            endIndex: docEnd - 1
          }
        }
      });
    }

    // Re-insert italic placeholder
    requests.push({
      insertText: {
        text: resetText,
        location: { index: newLiveStart }
      }
    });

    // Make it italic
    requests.push({
      updateTextStyle: {
        textStyle: {
          italic: true
        },
        range: {
          startIndex: newLiveStart,
          endIndex: newLiveStart + resetText.length
        },
        fields: 'italic'
      }
    });

    await docs.documents.batchUpdate({
      documentId,
      requestBody: { requests }
    });

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        message: 'Segment finalized successfully'
      })
    };

  } catch (error) {
    console.error('Error finalizing segment:', error);

    return {
      statusCode: 500,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        error: 'Failed to finalize segment',
        message: error.message
      })
    };
  }
};
