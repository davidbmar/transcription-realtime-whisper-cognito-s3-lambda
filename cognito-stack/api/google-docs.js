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

// Initialize document with live transcription section
// Uses inline formatting approach - finalized text is normal, in-progress is italic+gray
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

    // Add minimal header with timestamp
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

    // The finalized end index starts right after the header
    // All text after this will be the transcription (finalized + in-progress)
    const finalizedEndIndex = endIndex - 1 + headerText.length;

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        finalizedEndIndex,  // This is where finalized text ends (initially just after header)
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

// Update live transcription section with inline formatting
// Finalized text = normal, In-progress text = italic + gray
module.exports.updateLiveTranscription = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) updating Google Docs live transcription`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { documentId, finalizedEndIndex, finalizedText, inProgressText, isFinal } = body;

    if (!documentId || finalizedEndIndex === undefined) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'documentId and finalizedEndIndex are required' })
      };
    }

    const docs = getDocsClient();

    // Get current document to find where in-progress section is
    const doc = await docs.documents.get({ documentId });
    const docEnd = doc.data.body.content[doc.data.body.content.length - 1].endIndex;

    const requests = [];

    // Step 1: If there's finalized text, append it as normal text
    if (finalizedText && finalizedText.trim()) {
      requests.push({
        insertText: {
          text: finalizedText + ' ',
          location: { index: finalizedEndIndex }
        }
      });
    }

    // Step 2: Delete any existing in-progress text
    const inProgressStart = finalizedEndIndex + (finalizedText ? finalizedText.length + 1 : 0);
    if (docEnd - 1 > inProgressStart) {
      requests.push({
        deleteContentRange: {
          range: {
            startIndex: inProgressStart,
            endIndex: docEnd - 1
          }
        }
      });
    }

    // Step 3: Add new in-progress text with italic+gray formatting (if not final)
    if (inProgressText && inProgressText.trim() && !isFinal) {
      const inProgressInsertIndex = inProgressStart;

      // Insert the text first
      requests.push({
        insertText: {
          text: inProgressText,
          location: { index: inProgressInsertIndex }
        }
      });

      // Then format it (italic + gray color)
      requests.push({
        updateTextStyle: {
          range: {
            startIndex: inProgressInsertIndex,
            endIndex: inProgressInsertIndex + inProgressText.length
          },
          textStyle: {
            italic: true,
            foregroundColor: {
              color: {
                rgbColor: {
                  red: 0.5,
                  green: 0.5,
                  blue: 0.5
                }
              }
            }
          },
          fields: 'italic,foregroundColor'
        }
      });
    }

    // Execute all updates in one batch
    if (requests.length > 0) {
      await docs.documents.batchUpdate({
        documentId,
        requestBody: { requests }
      });
    }

    // Calculate new finalizedEndIndex
    const newFinalizedEndIndex = finalizedEndIndex + (finalizedText ? finalizedText.length + 1 : 0);

    return {
      statusCode: 200,
      headers: getSecurityHeaders(event.headers?.origin),
      body: JSON.stringify({
        success: true,
        finalizedEndIndex: newFinalizedEndIndex
      })
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

// Finalize transcription - add completion marker
// With inline formatting, finalization happens automatically in updateLiveTranscription
// This endpoint just adds a final timestamp marker when recording ends
module.exports.finalizeTranscription = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';

    console.log(`User ${email} (${userId}) finalizing Google Docs transcription`);

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const { documentId, finalizedEndIndex } = body;

    if (!documentId || finalizedEndIndex === undefined) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'documentId and finalizedEndIndex are required' })
      };
    }

    const docs = getDocsClient();

    // Get current document to remove any lingering in-progress text
    const doc = await docs.documents.get({ documentId });
    const docEnd = doc.data.body.content[doc.data.body.content.length - 1].endIndex;

    const timestamp = new Date().toLocaleString('en-US', {
      timeZone: 'America/New_York',
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });

    const requests = [];

    // Step 1: Delete any remaining in-progress text
    if (docEnd - 1 > finalizedEndIndex) {
      requests.push({
        deleteContentRange: {
          range: {
            startIndex: finalizedEndIndex,
            endIndex: docEnd - 1
          }
        }
      });
    }

    // Step 2: Add completion marker
    const completionMarker = `\n\n─────────────────────────────────────\n🎤 Transcription Ended: ${timestamp}\n─────────────────────────────────────\n`;

    requests.push({
      insertText: {
        text: completionMarker,
        location: { index: finalizedEndIndex }
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
        message: 'Transcription finalized successfully'
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
