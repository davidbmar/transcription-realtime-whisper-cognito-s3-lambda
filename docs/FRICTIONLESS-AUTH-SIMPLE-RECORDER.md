# Frictionless Audio Recording & Persistent Auth

## Design Document
**Version**: 1.0
**Date**: 2025-12-28
**Status**: Implementation In Progress

---

## Problem Statement

The current audio recorder has two friction points:

1. **Session Expiration**: Users are logged out after 1 hour (default Cognito token lifetime), requiring frequent re-authentication, especially frustrating on mobile devices.

2. **Complex UI**: The audio recorder page has 4,600+ lines of code with numerous options (system audio, diarization, Google Docs integration) that can overwhelm users who just want to quickly record audio.

---

## Goals

1. Users stay logged in for **30 days** without re-entering credentials
2. Recording can start **immediately** upon page load
3. Simple recorder shows **only a Record button** initially
4. Page refresh does not require manual login
5. Recordings are never lost (saved locally until upload succeeds)

---

## Technical Solution

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         FRONTEND                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐           │
│  │  Login Page  │───>│ Cognito      │───>│  Callback    │           │
│  │              │    │ Hosted UI    │    │  Handler     │           │
│  └──────────────┘    └──────────────┘    └──────┬───────┘           │
│                       code flow                  │                   │
│                                                  ▼                   │
│                                    ┌─────────────────────────┐      │
│                                    │   Auth Helper           │      │
│                                    │   (auth-helper.js)      │      │
│                                    │                         │      │
│                                    │   - access_token (RAM)  │      │
│                                    │   - auto-refresh        │      │
│                                    │   - 401 interceptor     │      │
│                                    └──────────┬──────────────┘      │
│                                               │                      │
│              ┌────────────────────────────────┼───────────────┐     │
│              │                                │               │     │
│              ▼                                ▼               ▼     │
│  ┌───────────────────┐     ┌───────────────────┐  ┌─────────────┐  │
│  │ Simple Recorder   │     │ Full Recorder     │  │ Other Pages │  │
│  │ (Big Red Button)  │     │ (audio.html)      │  │             │  │
│  └─────────┬─────────┘     └───────────────────┘  └─────────────┘  │
│            │                                                        │
│            ▼                                                        │
│  ┌───────────────────────────────────────────┐                     │
│  │           IndexedDB (audio-storage.js)    │                     │
│  │                                           │                     │
│  │   - Sessions: { sessionId, userId, ... }  │                     │
│  │   - Chunks: { blob, uploadStatus, ... }   │                     │
│  └─────────────────────────────────────────────┘                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 │ HTTPS + HttpOnly Cookie
                                 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         BACKEND                                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    API Gateway                                │  │
│  │                                                               │  │
│  │   POST /api/auth/callback  ─┐                                 │  │
│  │   POST /api/auth/refresh   ─┼──> Lambda (auth.js)             │  │
│  │   POST /api/auth/logout    ─┘                                 │  │
│  │                                                               │  │
│  │   GET/POST /api/*          ───> Lambda (Cognito authorizer)   │  │
│  │                                                               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                 │                                    │
│                                 ▼                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    Cognito User Pool                          │  │
│  │                                                               │  │
│  │   - Access Token: 15 minutes                                  │  │
│  │   - Refresh Token: 30 days                                    │  │
│  │   - Token rotation enabled                                    │  │
│  │                                                               │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Token Strategy

### Dual-Token System

| Token | Lifetime | Storage | Purpose |
|-------|----------|---------|---------|
| Access Token | 15 minutes | JavaScript memory | API authorization |
| ID Token | 15 minutes | localStorage (for backward compat) | User identity |
| Refresh Token | 30 days | HttpOnly cookie | Token renewal |

### Why HttpOnly Cookie for Refresh Token?

1. **XSS Protection**: JavaScript cannot access the cookie, so even if an attacker injects malicious code, they cannot steal the long-lived refresh token.

2. **Automatic Transmission**: Browser automatically sends the cookie with requests to the same origin, simplifying refresh logic.

3. **SameSite Protection**: `SameSite=Strict` prevents CSRF attacks.

### Token Rotation

On each refresh, a new refresh token is issued:

```
Request:  Cookie: refresh_token=token_v1
Response: Set-Cookie: refresh_token=token_v2; HttpOnly; Secure; SameSite=Strict
          Body: { access_token: "...", id_token: "..." }
```

If an attacker captures an old refresh token and tries to use it, the server detects the token has already been rotated and invalidates the entire session.

---

## API Endpoints

### POST /api/auth/callback

**Purpose**: Exchange authorization code for tokens after Cognito login

**Request**:
```json
{
  "code": "authorization_code_from_cognito",
  "redirect_uri": "https://app.example.com/callback.html"
}
```

**Response**:
```json
{
  "access_token": "eyJ...",
  "id_token": "eyJ...",
  "expires_in": 900
}
```

**Cookie Set**:
```
Set-Cookie: refresh_token=eyJ...; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000; Path=/
```

### POST /api/auth/refresh

**Purpose**: Get new access token using refresh token from cookie

**Request**: No body (refresh token read from cookie)

**Response**:
```json
{
  "access_token": "eyJ...",
  "id_token": "eyJ...",
  "expires_in": 900
}
```

**Cookie Set**: New rotated refresh token

### POST /api/auth/logout

**Purpose**: Clear refresh token cookie

**Response**:
```json
{ "success": true }
```

**Cookie Set**:
```
Set-Cookie: refresh_token=; HttpOnly; Secure; SameSite=Strict; Max-Age=0; Path=/
```

---

## Frontend Auth Helper

### Class: AuthHelper

```javascript
class AuthHelper {
  constructor(config) {
    this.apiUrl = config.apiUrl;
    this.accessToken = null;    // In memory only
    this.tokenExpiry = null;
    this.refreshPromise = null; // Single-flight pattern
  }

  // Get current access token
  getAccessToken() { return this.accessToken; }

  // Check if token expired or expiring soon (within 60s)
  isTokenExpired() {
    if (!this.tokenExpiry) return true;
    return Date.now() >= (this.tokenExpiry - 60000);
  }

  // Refresh token (single-flight: reuses existing promise)
  async refreshToken() {
    if (this.refreshPromise) return this.refreshPromise;
    this.refreshPromise = this._doRefresh();
    try { return await this.refreshPromise; }
    finally { this.refreshPromise = null; }
  }

  // Authenticated fetch with auto-retry on 401
  async authenticatedFetch(url, options = {}) {
    if (this.isTokenExpired()) await this.refreshToken();

    let response = await fetch(url, {
      ...options,
      headers: { ...options.headers, 'Authorization': `Bearer ${this.accessToken}` }
    });

    if (response.status === 401) {
      try {
        await this.refreshToken();
        response = await fetch(url, {
          ...options,
          headers: { ...options.headers, 'Authorization': `Bearer ${this.accessToken}` }
        });
      } catch {
        window.location.href = 'index.html';
        throw new Error('Session expired');
      }
    }

    return response;
  }
}
```

### Usage in Pages

```javascript
// Initialize once per page
const authHelper = initAuthHelper({ apiUrl: config.apiUrl });

// Make authenticated API calls
const response = await authHelper.authenticatedFetch('/api/files');
```

---

## Simple Recorder UI

### Design Principles

1. **Mobile-First**: Large touch targets, minimal scrolling
2. **Single Focus**: One action at a time
3. **Progressive Disclosure**: Advanced options hidden until needed
4. **Immediate Feedback**: Visual response to every action

### Layout

```
┌─────────────────────────────────┐
│  CloudDrive Header              │
├─────────────────────────────────┤
│                                 │
│                                 │
│         ┌───────────┐           │
│         │           │           │
│         │     ●     │           │  ← 140x140px red button
│         │           │           │
│         └───────────┘           │
│                                 │
│      Tap to start recording     │
│                                 │
│                                 │
│                                 │
│                                 │
│                                 │
│   Need more options? →          │  ← Link to full recorder
│                                 │
│                          ⚙️     │  ← Settings (bottom right)
└─────────────────────────────────┘

          During Recording:

┌─────────────────────────────────┐
│  CloudDrive Header              │
├─────────────────────────────────┤
│                                 │
│                                 │
│         ┌───────────┐           │
│         │   ┌───┐   │           │  ← Pulsing animation
│         │   │ ■ │   │           │  ← Square "stop" icon
│         │   └───┘   │           │
│         └───────────┘           │
│                                 │
│           02:34                 │  ← Duration counter
│                                 │
│                                 │
│                                 │
│                                 │
│                                 │
│                          ⚙️     │
└─────────────────────────────────┘

         After Recording:

┌─────────────────────────────────┐
│  CloudDrive Header              │
├─────────────────────────────────┤
│                                 │
│         ┌───────────┐           │
│         │           │           │
│         │     ●     │           │  ← Ready for new recording
│         │           │           │
│         └───────────┘           │
│                                 │
│           02:34                 │  ← Last recording duration
│                                 │
│   ┌─────────────────────────┐   │
│   │ 🎵 ▶ Recording 02:34    │   │  ← Playback preview
│   └─────────────────────────┘   │
│                                 │
│  [Discard]   [Play]   [Save]    │  ← Action buttons
│                                 │
│                          ⚙️     │
└─────────────────────────────────┘
```

### CSS Animation

```css
.record-btn {
  width: 140px;
  height: 140px;
  border-radius: 50%;
  border: 4px solid #ff4444;
  background: #ff4444;
  cursor: pointer;
  transition: transform 0.1s;
}

.record-btn:active {
  transform: scale(0.95);
}

.record-btn.recording {
  animation: pulse 1.5s ease-in-out infinite;
}

@keyframes pulse {
  0%, 100% { box-shadow: 0 0 0 0 rgba(255,68,68,0.4); }
  50% { box-shadow: 0 0 0 25px rgba(255,68,68,0); }
}

.record-btn.recording::before {
  content: '';
  position: absolute;
  inset: 35%;
  background: white;
  border-radius: 4px;  /* Square "stop" indicator */
}
```

---

## Record-First Logic

### Flow Diagram

```
┌───────────────────┐
│   Page Load       │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐     ┌────────────────────┐
│ Check pending     │────>│ Resume upload?     │
│ upload session    │     │ (from localStorage)│
└─────────┬─────────┘     └────────────────────┘
          │
          ▼
┌───────────────────┐
│ User taps Record  │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Create session in │
│ IndexedDB with    │
│ userId='pending'  │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Start MediaRecorder│
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ User taps Stop    │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Save blob to      │
│ IndexedDB         │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ User taps Upload  │
└─────────┬─────────┘
          │
          ▼
┌───────────────────────────────────┐
│ Check auth (try refresh)          │
│                                   │
│  Success?                         │
│  ├─ Yes: Upload to S3             │
│  └─ No:  Save sessionId,          │
│          redirect to login        │
└───────────────────────────────────┘
          │
          ▼ (after login callback)
┌───────────────────┐
│ Check localStorage│
│ for pending       │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Resume upload     │
│ from IndexedDB    │
└───────────────────┘
```

### Code Example

```javascript
// On page load
async function init() {
  // 1. Initialize IndexedDB (works offline)
  audioStorage = new AudioStorage();
  await audioStorage.init();

  // 2. Check for pending uploads from previous session
  const pendingSession = localStorage.getItem('pending_upload_session');
  if (pendingSession) {
    localStorage.removeItem('pending_upload_session');
    await resumePendingUpload(pendingSession);
  }

  // 3. Try to refresh auth (non-blocking)
  checkAuthStatus();
}

async function startRecording() {
  // Create session immediately (no auth required)
  sessionId = `quick-${Date.now()}`;
  await audioStorage.createSession({
    sessionId,
    userId: 'pending'  // Will update on upload
  });

  // Start recording...
}

async function uploadRecording() {
  try {
    await authHelper.refreshToken();
  } catch {
    // Auth failed - save for later and redirect
    localStorage.setItem('pending_upload_session', sessionId);
    window.location.href = 'index.html?return=simple-recorder.html';
    return;
  }

  // Auth succeeded - upload
  await doUpload(sessionId);
}
```

---

## Files Changed

### New Files
| File | Purpose |
|------|---------|
| `cognito-stack/api/auth.js` | Token exchange, refresh, logout Lambda handlers |
| `ui-source/lib/auth-helper.js` | Frontend auth module with fetch interceptor |
| `ui-source/simple-recorder.html.template` | Simple "big red button" recorder |

### Modified Files
| File | Changes |
|------|---------|
| `cognito-stack/serverless.yml` | Cognito token settings, new Lambda functions |
| `ui-source/callback.html` | Handle code flow with backend exchange |
| `ui-source/app.js.template` | Change `response_type` from `token` to `code` |
| `scripts/425-deploy-recorder-ui.sh` | Add simple-recorder to deployment |
| `.env` | Add `COGNITO_DOMAIN` |

---

## Backward Compatibility

1. **OAuth Flows**: Both `implicit` and `code` flows remain enabled in Cognito
2. **LocalStorage**: `id_token` still stored in localStorage for pages not yet updated
3. **Existing Pages**: Continue working with current token handling
4. **Gradual Migration**: Only new/updated pages use auth-helper

---

## Security Considerations

| Risk | Mitigation |
|------|------------|
| XSS stealing refresh token | HttpOnly cookie (JS cannot access) |
| CSRF attacks | SameSite=Strict cookie attribute |
| Token replay | Token rotation on each refresh |
| Long token exposure | 15-minute access token lifetime |
| Stolen refresh token | Token rotation invalidates old tokens |

---

## Testing Plan

### Unit Tests
- [ ] Auth.js: Code exchange happy path
- [ ] Auth.js: Refresh token rotation
- [ ] Auth.js: Invalid/expired token handling
- [ ] Auth-helper.js: 401 retry logic
- [ ] Auth-helper.js: Single-flight refresh

### Integration Tests
- [ ] Full login flow with code exchange
- [ ] Token refresh after 15 minutes
- [ ] 401 → refresh → retry pattern
- [ ] Offline recording → login → auto-upload

### Manual Tests
- [ ] Mobile Safari recording
- [ ] Mobile Chrome recording
- [ ] Page refresh retains session
- [ ] 30-day session persistence

---

## Rollback Plan

1. **Revert app.js.template**: Change `response_type` back to `token`
2. **Keep both flows**: Cognito still supports implicit flow
3. **Feature flag**: Don't deploy simple-recorder.html
4. **LocalStorage fallback**: Existing pages still work

---

## References

- [Cognito OAuth 2.0 Token Endpoint](https://docs.aws.amazon.com/cognito/latest/developerguide/token-endpoint.html)
- [RFC 6749: OAuth 2.0](https://datatracker.ietf.org/doc/html/rfc6749)
- [OWASP Token Storage Best Practices](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html)
