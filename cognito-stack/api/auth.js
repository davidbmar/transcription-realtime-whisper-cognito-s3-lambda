/**
 * Authentication Lambda Handlers
 *
 * Handles OAuth token exchange, refresh, and logout.
 * Stores refresh tokens in HttpOnly cookies for security.
 *
 * Endpoints:
 *   POST /api/auth/callback - Exchange authorization code for tokens
 *   POST /api/auth/refresh  - Refresh access token using cookie
 *   POST /api/auth/logout   - Clear refresh token cookie
 */

const https = require('https');

// Cookie configuration
const COOKIE_NAME = 'refresh_token';
const COOKIE_MAX_AGE = 30 * 24 * 60 * 60; // 30 days in seconds
const COOKIE_PATH = '/';

/**
 * Helper to get CORS headers with credentials support
 */
function getCorsHeaders() {
  const origin = process.env.CLOUDFRONT_URL || '*';
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Allow-Headers': 'Content-Type, Accept, Cookie',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json'
  };
}

/**
 * Build Set-Cookie header for refresh token
 */
function buildRefreshTokenCookie(refreshToken) {
  const isProduction = process.env.CLOUDFRONT_URL && process.env.CLOUDFRONT_URL.includes('https://');
  const secureFlag = isProduction ? 'Secure; ' : '';

  return `${COOKIE_NAME}=${refreshToken}; HttpOnly; ${secureFlag}SameSite=Strict; Max-Age=${COOKIE_MAX_AGE}; Path=${COOKIE_PATH}`;
}

/**
 * Build Set-Cookie header to clear the refresh token
 */
function buildClearCookie() {
  const isProduction = process.env.CLOUDFRONT_URL && process.env.CLOUDFRONT_URL.includes('https://');
  const secureFlag = isProduction ? 'Secure; ' : '';

  return `${COOKIE_NAME}=; HttpOnly; ${secureFlag}SameSite=Strict; Max-Age=0; Path=${COOKIE_PATH}`;
}

/**
 * Parse cookies from the Cookie header
 */
function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;

  cookieHeader.split(';').forEach(cookie => {
    const parts = cookie.split('=');
    if (parts.length >= 2) {
      const name = parts[0].trim();
      const value = parts.slice(1).join('=').trim();
      cookies[name] = value;
    }
  });

  return cookies;
}

/**
 * Make a request to Cognito's token endpoint
 */
function callCognitoTokenEndpoint(body) {
  return new Promise((resolve, reject) => {
    const cognitoDomain = process.env.COGNITO_DOMAIN;
    const region = process.env.AWS_COGNITO_REGION || process.env.AWS_REGION;

    // Build the full Cognito domain URL
    const hostname = cognitoDomain.includes('.amazoncognito.com')
      ? cognitoDomain
      : `${cognitoDomain}.auth.${region}.amazoncognito.com`;

    const options = {
      hostname: hostname,
      port: 443,
      path: '/oauth2/token',
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(body)
      }
    };

    console.log(`Calling Cognito token endpoint: https://${hostname}/oauth2/token`);

    const req = https.request(options, (res) => {
      let data = '';

      res.on('data', chunk => {
        data += chunk;
      });

      res.on('end', () => {
        if (res.statusCode === 200) {
          try {
            resolve(JSON.parse(data));
          } catch (e) {
            reject(new Error(`Failed to parse Cognito response: ${data}`));
          }
        } else {
          console.error(`Cognito token error: ${res.statusCode} - ${data}`);
          reject(new Error(`Cognito returned ${res.statusCode}: ${data}`));
        }
      });
    });

    req.on('error', (e) => {
      console.error('Cognito request error:', e);
      reject(e);
    });

    req.write(body);
    req.end();
  });
}

/**
 * POST /api/auth/callback
 *
 * Exchange authorization code for tokens.
 * Returns access_token and id_token in body, sets refresh_token in HttpOnly cookie.
 */
module.exports.callback = async (event) => {
  console.log('Auth callback request');

  try {
    // Parse request body
    let body;
    try {
      body = JSON.parse(event.body || '{}');
    } catch (e) {
      return {
        statusCode: 400,
        headers: getCorsHeaders(),
        body: JSON.stringify({ error: 'Invalid JSON body' })
      };
    }

    const { code, redirect_uri } = body;

    if (!code || !redirect_uri) {
      return {
        statusCode: 400,
        headers: getCorsHeaders(),
        body: JSON.stringify({ error: 'Missing required parameters: code, redirect_uri' })
      };
    }

    // Build token request body
    const clientId = process.env.COGNITO_USER_POOL_CLIENT_ID;
    const tokenBody = new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: clientId,
      code: code,
      redirect_uri: redirect_uri
    }).toString();

    console.log('Exchanging authorization code for tokens');

    // Call Cognito token endpoint
    const tokenResponse = await callCognitoTokenEndpoint(tokenBody);

    console.log('Token exchange successful');

    // Build response with refresh token in HttpOnly cookie
    const responseHeaders = getCorsHeaders();
    responseHeaders['Set-Cookie'] = buildRefreshTokenCookie(tokenResponse.refresh_token);

    return {
      statusCode: 200,
      headers: responseHeaders,
      body: JSON.stringify({
        access_token: tokenResponse.access_token,
        id_token: tokenResponse.id_token,
        expires_in: tokenResponse.expires_in,
        token_type: tokenResponse.token_type
      })
    };

  } catch (error) {
    console.error('Auth callback error:', error);

    // Check if it's a Cognito error
    if (error.message && error.message.includes('Cognito returned')) {
      return {
        statusCode: 401,
        headers: getCorsHeaders(),
        body: JSON.stringify({
          error: 'Authentication failed',
          message: 'Invalid or expired authorization code'
        })
      };
    }

    return {
      statusCode: 500,
      headers: getCorsHeaders(),
      body: JSON.stringify({
        error: 'Internal server error',
        message: error.message
      })
    };
  }
};

/**
 * POST /api/auth/refresh
 *
 * Refresh access token using refresh_token from HttpOnly cookie.
 * Returns new access_token and id_token, sets new refresh_token cookie (rotation).
 */
module.exports.refresh = async (event) => {
  console.log('Auth refresh request');

  try {
    // Parse cookies from request
    const cookieHeader = event.headers?.Cookie || event.headers?.cookie || '';
    const cookies = parseCookies(cookieHeader);
    const refreshToken = cookies[COOKIE_NAME];

    if (!refreshToken) {
      console.log('No refresh token found in cookies');
      return {
        statusCode: 401,
        headers: getCorsHeaders(),
        body: JSON.stringify({
          error: 'No refresh token',
          message: 'Please log in again'
        })
      };
    }

    // Build token request body
    const clientId = process.env.COGNITO_USER_POOL_CLIENT_ID;
    const tokenBody = new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: clientId,
      refresh_token: refreshToken
    }).toString();

    console.log('Refreshing access token');

    // Call Cognito token endpoint
    const tokenResponse = await callCognitoTokenEndpoint(tokenBody);

    console.log('Token refresh successful');

    // Build response headers
    const responseHeaders = getCorsHeaders();

    // If Cognito returns a new refresh token (token rotation), set it
    // Note: Cognito may or may not return a new refresh_token depending on settings
    if (tokenResponse.refresh_token) {
      responseHeaders['Set-Cookie'] = buildRefreshTokenCookie(tokenResponse.refresh_token);
    }

    return {
      statusCode: 200,
      headers: responseHeaders,
      body: JSON.stringify({
        access_token: tokenResponse.access_token,
        id_token: tokenResponse.id_token,
        expires_in: tokenResponse.expires_in,
        token_type: tokenResponse.token_type
      })
    };

  } catch (error) {
    console.error('Auth refresh error:', error);

    // If refresh failed, clear the cookie and return 401
    if (error.message && error.message.includes('Cognito returned')) {
      const responseHeaders = getCorsHeaders();
      responseHeaders['Set-Cookie'] = buildClearCookie();

      return {
        statusCode: 401,
        headers: responseHeaders,
        body: JSON.stringify({
          error: 'Session expired',
          message: 'Please log in again'
        })
      };
    }

    return {
      statusCode: 500,
      headers: getCorsHeaders(),
      body: JSON.stringify({
        error: 'Internal server error',
        message: error.message
      })
    };
  }
};

/**
 * POST /api/auth/logout
 *
 * Clear the refresh token cookie.
 */
module.exports.logout = async (event) => {
  console.log('Auth logout request');

  try {
    const responseHeaders = getCorsHeaders();
    responseHeaders['Set-Cookie'] = buildClearCookie();

    return {
      statusCode: 200,
      headers: responseHeaders,
      body: JSON.stringify({
        success: true,
        message: 'Logged out successfully'
      })
    };

  } catch (error) {
    console.error('Auth logout error:', error);
    return {
      statusCode: 500,
      headers: getCorsHeaders(),
      body: JSON.stringify({
        error: 'Internal server error',
        message: error.message
      })
    };
  }
};
