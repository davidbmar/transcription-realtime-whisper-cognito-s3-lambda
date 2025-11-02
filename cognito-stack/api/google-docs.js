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

    const headerInsertIndex = endIndex - 1;
    await docs.documents.batchUpdate({
      documentId,
      requestBody: {
        requests: [
          {
            insertText: {
              text: headerText,
              location: { index: headerInsertIndex }
            }
          },
          {
            updateTextStyle: {
              textStyle: {
                italic: false
              },
              range: {
                startIndex: headerInsertIndex,
                endIndex: headerInsertIndex + headerText.length
              },
              fields: 'italic'
            }
          }
        ]
      }
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

    // IGNORE stale frontend index - find live section dynamically!
    // Same strategy as finalize: find last session, then first italic after it

    let lastSessionStart = null;
    const content = doc.data.body.content;

    // Find the last "🎤 Live Transcription Started:" header
    for (let i = content.length - 1; i >= 0; i--) {
      const element = content[i];
      if (element.paragraph && element.paragraph.elements) {
        for (const textElement of element.paragraph.elements) {
          if (textElement.textRun && textElement.textRun.content.includes('🎤 Live Transcription Started:')) {
            lastSessionStart = element.startIndex;
            break;
          }
        }
        if (lastSessionStart !== null) break;
      }
    }

    if (lastSessionStart === null) {
      throw new Error('Could not find session header for live update');
    }

    // Find the first italic text AFTER the last session header
    let actualLiveStart = null;
    for (let i = 0; i < content.length; i++) {
      const element = content[i];
      if (element.startIndex && element.startIndex < lastSessionStart) continue;

      if (element.paragraph && element.paragraph.elements) {
        for (const textElement of element.paragraph.elements) {
          if (textElement.textRun) {
            const isItalic = textElement.textRun.textStyle?.italic === true;
            if (isItalic && textElement.textRun.content.trim() && textElement.startIndex > lastSessionStart) {
              actualLiveStart = textElement.startIndex;
              break;
            }
          }
        }
        if (actualLiveStart !== null) break;
      }
    }

    if (actualLiveStart === null) {
      throw new Error('Could not find italic live section for update');
    }

    console.log(`Update: Found session at ${lastSessionStart}, live at ${actualLiveStart}`);

    // Delete and replace the live section
    const newText = text + '\n';
    const requests = [
      // Delete current live section content
      {
        deleteContentRange: {
          range: {
            startIndex: actualLiveStart,
            endIndex: docEnd - 1
          }
        }
      },
      // Insert new live text
      {
        insertText: {
          text: newText,
          location: { index: actualLiveStart }
        }
      },
      // Make it italic
      {
        updateTextStyle: {
          textStyle: {
            italic: true
          },
          range: {
            startIndex: actualLiveStart,
            endIndex: actualLiveStart + newText.length
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
    const { documentId, liveStartIndex, text, paragraph_break } = body;

    if (!documentId || !text) {
      return {
        statusCode: 400,
        headers: getSecurityHeaders(event.headers?.origin),
        body: JSON.stringify({ error: 'documentId and text are required' })
      };
    }

    // Log paragraph break info
    if (paragraph_break) {
      console.log(`📄 Paragraph break requested for segment: "${text.substring(0, 50)}..."`);
    }

    const docs = getDocsClient();

    // NEW STRATEGY: Ignore frontend indices entirely
    // Find the LAST italic section in the document (that's the live section)
    // Insert finalized text before it, then reset the live section

    const doc = await docs.documents.get({ documentId });
    const docEnd = doc.data.body.content[doc.data.body.content.length - 1].endIndex;

    // Strategy: Find the LAST session header, then find italic text AFTER it
    // This ensures we're working with the current session only

    let lastSessionStart = null;
    const content = doc.data.body.content;

    // First, find the last "🎤 Live Transcription Started:" header
    for (let i = content.length - 1; i >= 0; i--) {
      const element = content[i];
      if (element.paragraph && element.paragraph.elements) {
        for (const textElement of element.paragraph.elements) {
          if (textElement.textRun && textElement.textRun.content.includes('🎤 Live Transcription Started:')) {
            lastSessionStart = element.startIndex;
            break;
          }
        }
        if (lastSessionStart !== null) break;
      }
    }

    if (lastSessionStart === null) {
      throw new Error('Could not find session header in document');
    }

    // Now find the first italic text AFTER the last session header
    let liveStart = null;
    for (let i = 0; i < content.length; i++) {
      const element = content[i];
      if (element.startIndex && element.startIndex < lastSessionStart) continue; // Skip elements before last session

      if (element.paragraph && element.paragraph.elements) {
        for (const textElement of element.paragraph.elements) {
          if (textElement.textRun) {
            const isItalic = textElement.textRun.textStyle?.italic === true;
            if (isItalic && textElement.textRun.content.trim() && textElement.startIndex > lastSessionStart) {
              // Found it - this is where live section starts in the current session
              liveStart = textElement.startIndex;
              break;
            }
          }
        }
        if (liveStart !== null) break;
      }
    }

    if (liveStart === null) {
      throw new Error('Could not find italic live section after session header');
    }

    console.log(`Found session at ${lastSessionStart}, live section at ${liveStart}`);
    console.log(`Inserting finalized text: "${text.substring(0, 50)}..."`);

    // Use paragraph break (\n\n) if pause exceeded threshold, otherwise just space
    const separator = paragraph_break ? '\n\n' : ' ';
    const finalizedText = text + separator;
    const resetText = '[Listening...]\n';

    // CORRECT order: Delete first, then insert
    // Google Docs processes requests in reverse order for inserts/deletes
    const requests = [];

    // 1. Delete old live section first (if it has content)
    if (liveStart < docEnd - 1) {
      requests.push({
        deleteContentRange: {
          range: {
            startIndex: liveStart,
            endIndex: docEnd - 1
          }
        }
      });
    }

    // 2. Insert finalized text at where live section WAS
    requests.push({
      insertText: {
        text: finalizedText,
        location: { index: liveStart }
      }
    });

    // 3. Format finalized text as normal (explicitly reset italic)
    requests.push({
      updateTextStyle: {
        textStyle: {
          italic: false,
          bold: false
        },
        range: {
          startIndex: liveStart,
          endIndex: liveStart + finalizedText.length
        },
        fields: 'italic,bold'
      }
    });

    // 4. Insert new italic placeholder after finalized text
    const newLiveStart = liveStart + finalizedText.length;
    requests.push({
      insertText: {
        text: resetText,
        location: { index: newLiveStart }
      }
    });

    // 5. Format placeholder as italic
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
