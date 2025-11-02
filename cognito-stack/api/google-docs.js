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

    const headerText = `\n\n─────────────────────────────────────\n🎤 Live Transcription Started: ${timestamp}\n─────────────────────────────────────\n\n[Transcription will appear here as it's finalized]\n\n🔴 LIVE:\n[Listening...]\n`;

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

    // Calculate where the live section starts
    const liveStartIndex = endIndex - 1 + headerText.lastIndexOf('🔴 LIVE:\n') + '🔴 LIVE:\n'.length;

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

    // Simple approach: Delete everything in live section and replace with new text
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
          text: text + '\n',
          location: { index: liveStartIndex }
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

    // Get current document
    const doc = await docs.documents.get({ documentId });
    const docEnd = doc.data.body.content[doc.data.body.content.length - 1].endIndex;

    const requests = [];

    // Step 1: Add finalized text to the permanent section (before live section)
    // Find the "🔴 LIVE:" marker
    const liveSectionStart = liveStartIndex - '🔴 LIVE:\n'.length;

    requests.push({
      insertText: {
        text: text + ' ',
        location: { index: liveSectionStart }
      }
    });

    // Step 2: Clear the live section (replace with "[Listening...]")
    const newLiveStart = liveSectionStart + text.length + 1 + '🔴 LIVE:\n'.length;
    requests.push({
      deleteContentRange: {
        range: {
          startIndex: newLiveStart,
          endIndex: docEnd - 1
        }
      }
    });

    requests.push({
      insertText: {
        text: '[Listening...]\n',
        location: { index: newLiveStart }
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
