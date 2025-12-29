/**
 * Authentication Helper Module
 *
 * Provides:
 * - In-memory access token storage (not localStorage)
 * - Automatic token refresh before expiration
 * - 401 retry logic with automatic re-authentication
 * - Single-flight refresh pattern (prevents concurrent refresh calls)
 *
 * Usage:
 *   const authHelper = initAuthHelper({ apiUrl: 'https://api.example.com' });
 *   const response = await authHelper.authenticatedFetch('/api/data');
 */

(function(window) {
  'use strict';

  // Token refresh buffer - refresh 60 seconds before expiry
  const REFRESH_BUFFER_MS = 60 * 1000;

  /**
   * AuthHelper Class
   *
   * Manages authentication tokens with automatic refresh and retry logic.
   */
  class AuthHelper {
    constructor(config) {
      this.apiUrl = config.apiUrl;
      this.accessToken = null;
      this.idToken = null;
      this.tokenExpiry = null;
      this.refreshPromise = null; // For single-flight pattern
      this.onLogout = config.onLogout || null;

      // Bind methods
      this.getAccessToken = this.getAccessToken.bind(this);
      this.getIdToken = this.getIdToken.bind(this);
      this.isTokenExpired = this.isTokenExpired.bind(this);
      this.refreshToken = this.refreshToken.bind(this);
      this.authenticatedFetch = this.authenticatedFetch.bind(this);
      this.setTokens = this.setTokens.bind(this);
      this.logout = this.logout.bind(this);
    }

    /**
     * Get the current access token
     * @returns {string|null} The access token or null if not authenticated
     */
    getAccessToken() {
      return this.accessToken;
    }

    /**
     * Get the current ID token
     * @returns {string|null} The ID token or null if not authenticated
     */
    getIdToken() {
      return this.idToken;
    }

    /**
     * Check if the token is expired or about to expire
     * @returns {boolean} True if token is expired or expiring within buffer
     */
    isTokenExpired() {
      if (!this.accessToken || !this.tokenExpiry) {
        return true;
      }
      return Date.now() >= (this.tokenExpiry - REFRESH_BUFFER_MS);
    }

    /**
     * Check if we have any tokens (even if expired)
     * @returns {boolean} True if tokens are present
     */
    hasTokens() {
      return !!this.accessToken;
    }

    /**
     * Set tokens from a token response
     * @param {string} accessToken - The access token
     * @param {string} idToken - The ID token
     * @param {number} expiresIn - Seconds until expiry (optional)
     */
    setTokens(accessToken, idToken, expiresIn = null) {
      this.accessToken = accessToken;
      this.idToken = idToken;

      if (expiresIn) {
        // Use provided expiry
        this.tokenExpiry = Date.now() + (expiresIn * 1000);
      } else {
        // Parse JWT to get expiry
        try {
          const payload = JSON.parse(atob(accessToken.split('.')[1]));
          this.tokenExpiry = payload.exp * 1000;
        } catch (e) {
          console.warn('[AuthHelper] Could not parse token expiry, using 15 minutes');
          this.tokenExpiry = Date.now() + (15 * 60 * 1000);
        }
      }

      // Store id_token in localStorage for backward compatibility
      // Access token stays in memory only
      if (idToken) {
        localStorage.setItem('id_token', idToken);
      }

      console.log('[AuthHelper] Tokens set, expiry:', new Date(this.tokenExpiry).toLocaleTimeString());
    }

    /**
     * Refresh the access token using the HttpOnly refresh token cookie
     * Uses single-flight pattern to prevent concurrent refresh calls
     * @returns {Promise<Object>} The token response
     */
    async refreshToken() {
      // Single-flight: reuse existing promise if refresh is in progress
      if (this.refreshPromise) {
        console.log('[AuthHelper] Refresh already in progress, waiting...');
        return this.refreshPromise;
      }

      console.log('[AuthHelper] Starting token refresh');

      this.refreshPromise = this._doRefresh();

      try {
        const result = await this.refreshPromise;
        return result;
      } finally {
        this.refreshPromise = null;
      }
    }

    /**
     * Internal refresh implementation
     * @private
     */
    async _doRefresh() {
      try {
        // Check for localStorage refresh token first (fallback for 3rd-party cookie blocking)
        const storedRefreshToken = localStorage.getItem('refresh_token');

        // Build request - include refresh_token in body if we have one
        const requestOptions = {
          method: 'POST',
          credentials: 'include', // Include HttpOnly cookies
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          }
        };

        if (storedRefreshToken) {
          console.log('[AuthHelper] Using localStorage refresh token');
          requestOptions.body = JSON.stringify({ refresh_token: storedRefreshToken });
        }

        const response = await fetch(`${this.apiUrl}/api/auth/refresh`, requestOptions);

        if (!response.ok) {
          const errorData = await response.json().catch(() => ({ error: 'Unknown error' }));
          console.error('[AuthHelper] Refresh failed:', response.status, errorData);

          // Clear tokens on auth failure
          this.accessToken = null;
          this.idToken = null;
          this.tokenExpiry = null;
          localStorage.removeItem('id_token');
          localStorage.removeItem('access_token');
          localStorage.removeItem('refresh_token');

          throw new Error(errorData.message || 'Token refresh failed');
        }

        const data = await response.json();
        this.setTokens(data.access_token, data.id_token, data.expires_in);

        // Update stored refresh token if rotated
        if (data.refresh_token) {
          localStorage.setItem('refresh_token', data.refresh_token);
        }

        console.log('[AuthHelper] Token refresh successful');

        return data;
      } catch (error) {
        console.error('[AuthHelper] Refresh error:', error);
        throw error;
      }
    }

    /**
     * Make an authenticated fetch request with automatic token refresh and 401 retry
     * @param {string} url - The URL to fetch
     * @param {Object} options - Fetch options
     * @returns {Promise<Response>} The fetch response
     */
    async authenticatedFetch(url, options = {}) {
      // Pre-check: refresh if token is expired or about to expire
      if (this.isTokenExpired()) {
        try {
          console.log('[AuthHelper] Token expired, refreshing before request');
          await this.refreshToken();
        } catch (e) {
          console.error('[AuthHelper] Pre-request refresh failed:', e);
          // Let the request proceed anyway - might still work if token is valid
        }
      }

      // Build request with auth header
      // Note: Cognito authorizers expect the ID token, not access token
      const makeRequest = async () => {
        const headers = {
          ...options.headers
        };

        if (this.idToken) {
          headers['Authorization'] = `Bearer ${this.idToken}`;
        }

        return fetch(url, {
          ...options,
          headers,
          credentials: options.credentials || 'include'
        });
      };

      // Make the request
      let response = await makeRequest();

      // Handle 401: try refresh once, then retry
      if (response.status === 401) {
        console.log('[AuthHelper] Got 401, attempting token refresh and retry');

        try {
          await this.refreshToken();
          response = await makeRequest();
        } catch (e) {
          console.error('[AuthHelper] 401 retry failed:', e);

          // Refresh failed - trigger logout callback
          if (this.onLogout) {
            this.onLogout();
          } else {
            // Default: redirect to home/login
            window.location.href = 'index.html';
          }

          throw new Error('Session expired. Please log in again.');
        }
      }

      return response;
    }

    /**
     * Log out: clear tokens and call logout endpoint
     * @param {string} redirectUrl - Optional URL to redirect to after logout
     */
    async logout(redirectUrl = 'index.html') {
      console.log('[AuthHelper] Logging out');

      // Clear in-memory tokens
      this.accessToken = null;
      this.idToken = null;
      this.tokenExpiry = null;

      // Clear localStorage tokens
      localStorage.removeItem('id_token');
      localStorage.removeItem('access_token');
      localStorage.removeItem('refresh_token');

      // Clear all Cognito-related items
      const keys = Object.keys(localStorage);
      for (const key of keys) {
        if (key.includes('CognitoIdentityServiceProvider') ||
            key.includes('amplify') ||
            key.includes('aws')) {
          localStorage.removeItem(key);
        }
      }

      // Call logout endpoint to clear HttpOnly cookie
      try {
        await fetch(`${this.apiUrl}/api/auth/logout`, {
          method: 'POST',
          credentials: 'include',
          headers: {
            'Content-Type': 'application/json'
          }
        });
      } catch (e) {
        console.warn('[AuthHelper] Logout endpoint call failed:', e);
        // Continue with redirect anyway
      }

      // Redirect
      if (redirectUrl) {
        window.location.href = redirectUrl;
      }
    }

    /**
     * Initialize from existing localStorage token (for backward compatibility)
     * Attempts to refresh if a localStorage token exists
     * @returns {Promise<boolean>} True if successfully initialized
     */
    async initFromStorage() {
      const storedIdToken = localStorage.getItem('id_token');

      if (storedIdToken) {
        console.log('[AuthHelper] Found stored token, attempting refresh');

        try {
          await this.refreshToken();
          return true;
        } catch (e) {
          console.log('[AuthHelper] Stored token refresh failed, user needs to log in');
          return false;
        }
      }

      return false;
    }
  }

  // Singleton instance
  let authHelperInstance = null;

  /**
   * Initialize or get the AuthHelper singleton
   * @param {Object} config - Configuration object with apiUrl
   * @returns {AuthHelper} The AuthHelper instance
   */
  function initAuthHelper(config) {
    if (!authHelperInstance) {
      if (!config || !config.apiUrl) {
        throw new Error('AuthHelper requires config.apiUrl');
      }
      authHelperInstance = new AuthHelper(config);
    }
    return authHelperInstance;
  }

  /**
   * Get the existing AuthHelper instance (must be initialized first)
   * @returns {AuthHelper|null} The AuthHelper instance or null
   */
  function getAuthHelper() {
    return authHelperInstance;
  }

  // Export to window
  window.AuthHelper = AuthHelper;
  window.initAuthHelper = initAuthHelper;
  window.getAuthHelper = getAuthHelper;

})(window);
