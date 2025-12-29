/**
 * CloudDrive Header Component
 *
 * Renders a consistent header/breadcrumb across all CloudDrive pages.
 * Provides navigation back to dashboard and displays current page context.
 *
 * Usage:
 *   <link rel="stylesheet" href="lib/clouddrive-header.css">
 *   <div id="clouddrive-header"
 *        data-page="Live Record"
 *        data-icon="microphone"
 *        data-show-user="true">
 *   </div>
 *   <script src="lib/clouddrive-header.js"></script>
 *
 * Configuration via data attributes:
 *   - data-page: Page name for breadcrumb (empty = no breadcrumb, just logo)
 *   - data-icon: FontAwesome icon name (without 'fa-' prefix)
 *   - data-show-user: "true" to show user email and logout button
 *   - data-home-url: Override home URL (default: "index.html")
 */

class CloudDriveHeader {
  constructor(containerId = 'clouddrive-header') {
    this.container = document.getElementById(containerId);
    if (!this.container) {
      console.warn('[CloudDriveHeader] Container not found:', containerId);
      return;
    }

    // Read configuration from data attributes
    this.config = {
      page: this.container.dataset.page || '',
      icon: this.container.dataset.icon || 'file',
      showUser: this.container.dataset.showUser === 'true',
      homeUrl: this.container.dataset.homeUrl || 'index.html'
    };

    this.render();
    this.setupEventListeners();
  }

  /**
   * Get current user email from Cognito localStorage
   * Tries multiple sources: JWT token, userData, then falls back gracefully
   */
  getUserEmail() {
    try {
      const keys = Object.keys(localStorage);

      // Method 1: Try to decode email from idToken JWT (most reliable)
      for (const key of keys) {
        if (key.includes('CognitoIdentityServiceProvider') && key.includes('.idToken')) {
          const idToken = localStorage.getItem(key);
          if (idToken) {
            try {
              const payload = JSON.parse(atob(idToken.split('.')[1]));
              if (payload.email) return payload.email;
              // Some Cognito configs use 'cognito:username' which might be email
              if (payload['cognito:username'] && payload['cognito:username'].includes('@')) {
                return payload['cognito:username'];
              }
            } catch (e) {}
          }
        }
      }

      // Method 2: Try legacy id_token key
      const legacyToken = localStorage.getItem('id_token');
      if (legacyToken) {
        try {
          const payload = JSON.parse(atob(legacyToken.split('.')[1]));
          if (payload.email) return payload.email;
        } catch (e) {}
      }

      // Method 3: Try userData from Cognito
      for (const key of keys) {
        if (key.includes('CognitoIdentityServiceProvider') && key.includes('LastAuthUser')) {
          const clientId = key.split('.')[1];
          const username = localStorage.getItem(key);
          if (username) {
            const userDataKey = `CognitoIdentityServiceProvider.${clientId}.${username}.userData`;
            const userData = localStorage.getItem(userDataKey);
            if (userData) {
              try {
                const parsed = JSON.parse(userData);
                const emailAttr = parsed.UserAttributes?.find(a => a.Name === 'email');
                if (emailAttr) return emailAttr.Value;
              } catch (e) {}
            }
            // Only use username as fallback if it looks like an email
            if (username.includes('@')) {
              return username;
            }
          }
        }
      }
    } catch (e) {
      console.warn('[CloudDriveHeader] Error getting user email:', e);
    }
    return null;
  }

  /**
   * Handle logout - clear all auth tokens and redirect
   */
  logout() {
    try {
      // Clear direct token keys used by the app
      localStorage.removeItem('id_token');
      localStorage.removeItem('access_token');
      localStorage.removeItem('refresh_token');

      // Clear all Cognito-related localStorage items
      const keys = Object.keys(localStorage);
      for (const key of keys) {
        if (key.includes('CognitoIdentityServiceProvider') ||
            key.includes('amplify') ||
            key.includes('aws')) {
          localStorage.removeItem(key);
        }
      }
      // Redirect to home/login
      window.location.href = this.config.homeUrl;
    } catch (e) {
      console.error('[CloudDriveHeader] Logout error:', e);
      window.location.href = this.config.homeUrl;
    }
  }

  /**
   * Render the header HTML
   */
  render() {
    const userEmail = this.config.showUser ? this.getUserEmail() : null;
    const showBreadcrumb = this.config.page && this.config.page.trim() !== '';

    this.container.innerHTML = `
      <header class="cd-header">
        <div class="cd-header-left">
          <a href="${this.config.homeUrl}" class="cd-logo" title="Go to Dashboard">
            <i class="fas fa-cloud"></i>
            <span>CloudDrive</span>
          </a>
          ${showBreadcrumb ? `
            <nav class="cd-breadcrumb" aria-label="Breadcrumb">
              <span class="cd-breadcrumb-separator" aria-hidden="true">›</span>
              <span class="cd-breadcrumb-current">
                <i class="fas fa-${this.config.icon}"></i>
                <span>${this.escapeHtml(this.config.page)}</span>
              </span>
            </nav>
          ` : ''}
        </div>
        <div class="cd-header-right">
          ${this.config.showUser ? `
            ${userEmail ? `<span class="cd-user-email" title="${this.escapeHtml(userEmail)}">${this.escapeHtml(userEmail)}</span>` : ''}
            <a href="profile.html?ref=${encodeURIComponent(window.location.href)}" class="cd-settings-icon" title="Account Settings">
              <i class="fas fa-cog"></i>
            </a>
            <button class="cd-btn cd-btn-danger" id="cd-logout-btn" title="Sign out">
              <i class="fas fa-sign-out-alt"></i>
              <span>Sign Out</span>
            </button>
          ` : ''}
        </div>
      </header>
    `;
  }

  /**
   * Setup event listeners
   */
  setupEventListeners() {
    const logoutBtn = document.getElementById('cd-logout-btn');
    if (logoutBtn) {
      logoutBtn.addEventListener('click', () => this.logout());
    }
  }

  /**
   * Update the current page (for dynamic pages like dashboard)
   * @param {string} pageName - New page name
   * @param {string} iconClass - FontAwesome icon name (without 'fa-' prefix)
   */
  setPage(pageName, iconClass = null) {
    this.config.page = pageName;
    if (iconClass) this.config.icon = iconClass;
    this.render();
    this.setupEventListeners();
  }

  /**
   * Escape HTML to prevent XSS
   */
  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
}

// Auto-initialize when DOM is ready (with guard against double initialization)
function initCloudDriveHeader() {
  if (!window.cloudDriveHeader) {
    window.cloudDriveHeader = new CloudDriveHeader();
  }
}

document.addEventListener('DOMContentLoaded', initCloudDriveHeader);

// Also try to initialize immediately if DOM is already loaded
if (document.readyState === 'complete' || document.readyState === 'interactive') {
  initCloudDriveHeader();
}
