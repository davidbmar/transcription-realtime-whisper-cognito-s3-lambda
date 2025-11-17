#!/bin/bash
# ============================================================================
# 425-deploy-recorder-ui.sh
# ============================================================================
# Description: Deploy full audio recorder UI with Cognito authentication
# 
# This script:
#   1. Copies recorder UI files from audio-ui-cf-s3-lambda-cognito
#   2. Updates configuration with current Cognito deployment values
#   3. Uploads files to S3
#   4. Invalidates CloudFront cache
#
# Prerequisites:
#   - Script 420 completed successfully
#   - Cognito stack deployed
#   - .env populated with deployment outputs
#
# Total time: ~2-3 minutes
# ============================================================================

# Find repository root (works from symlink or direct execution)
SCRIPT_PATH="$0"
if [ -L "$SCRIPT_PATH" ]; then
    SCRIPT_REAL="$(readlink -f "$SCRIPT_PATH")"
else
    SCRIPT_REAL="$SCRIPT_PATH"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

# Load library functions
source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

# Change to repository root
cd "$REPO_ROOT"

# Script header
echo "============================================"
echo "425: Deploy Recorder UI"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Copy recorder UI from audio-ui-cf-s3-lambda-cognito"
log_info "  2. Update configuration with Cognito values"
log_info "  3. Upload files to S3"
log_info "  4. Invalidate CloudFront cache"
echo ""

# Validate prerequisites
log_info "Step 1: Validating prerequisites"

# Auto-detect source UI directory (look in common locations)
# Prefer local ui-source directory for self-contained deployment
POSSIBLE_LOCATIONS=(
    "$(dirname "$0")/../ui-source"
    "/home/ubuntu/event-b/audio-ui-cf-s3-lambda-cognito/web"
    "../audio-ui-cf-s3-lambda-cognito/web"
    "../../audio-ui-cf-s3-lambda-cognito/web"
)

SOURCE_UI_DIR=""
for location in "${POSSIBLE_LOCATIONS[@]}"; do
    if [ -d "$location" ]; then
        SOURCE_UI_DIR="$(cd "$location" && pwd)"
        break
    fi
done

if [ -z "$SOURCE_UI_DIR" ]; then
    log_error "Source UI directory not found. Tried:"
    for location in "${POSSIBLE_LOCATIONS[@]}"; do
        log_error "  - $location"
    done
    log_error ""
    log_error "Please clone the UI repo:"
    log_error "  git clone https://github.com/davidbmar/audio-ui-cf-s3-lambda-cognito.git"
    log_error ""
    log_error "Expected directory structure:"
    log_error "  parent-dir/"
    log_error "    ├── transcription-realtime-whisper-cognito-s3-lambda-ver4/"
    log_error "    └── audio-ui-cf-s3-lambda-cognito/"
    exit 1
fi

# Check required env variables
REQUIRED_VARS=("COGNITO_USER_POOL_ID" "COGNITO_USER_POOL_CLIENT_ID" "COGNITO_IDENTITY_POOL_ID" 
               "COGNITO_API_ENDPOINT" "COGNITO_CLOUDFRONT_URL" "COGNITO_S3_BUCKET" "AWS_REGION")

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Required environment variable $var is not set"
        log_info "Please run ./scripts/420-deploy-cognito-stack.sh first"
        exit 1
    fi
done

log_success "Prerequisites validated"
echo ""

# Navigate to cognito-stack directory
log_info "Step 2: Preparing cognito-stack/web directory"
cd "$REPO_ROOT/cognito-stack"
mkdir -p web
cd web

log_success "Directory prepared"
echo ""

# Copy UI files
log_info "Step 3: Copying UI files from audio-ui-cf-s3-lambda-cognito"
log_info "Source: $SOURCE_UI_DIR"

# Copy the main UI files
cp "$SOURCE_UI_DIR/index.html" ./
cp "$SOURCE_UI_DIR/audio-ui-styles.css" ./
cp "$SOURCE_UI_DIR/styles.css" ./

# Use audio.html with WhisperLive integration
cp "$SOURCE_UI_DIR/audio.html" ./audio.html

# Copy transcript editor templates (will be processed later)
if [ -f "$SOURCE_UI_DIR/transcript-editor.html.template" ]; then
    cp "$SOURCE_UI_DIR/transcript-editor.html.template" ./transcript-editor.html
    log_info "  - Copied transcript-editor.html.template"
else
    log_warn "  - transcript-editor.html.template not found (skipping)"
fi

if [ -f "$SOURCE_UI_DIR/transcript-editor-v2.html.template" ]; then
    cp "$SOURCE_UI_DIR/transcript-editor-v2.html.template" ./transcript-editor-v2.html
    log_info "  - Copied transcript-editor-v2.html.template"
else
    log_warn "  - transcript-editor-v2.html.template not found (skipping)"
fi

# Copy JavaScript libraries from ui-source
if [ -f "$SOURCE_UI_DIR/transcript-preprocessor-simple.js" ]; then
    cp "$SOURCE_UI_DIR/transcript-preprocessor-simple.js" ./
    log_info "  - Copied transcript-preprocessor-simple.js"
fi

if [ -f "$SOURCE_UI_DIR/transcript-preprocessor.js" ]; then
    cp "$SOURCE_UI_DIR/transcript-preprocessor.js" ./
    log_info "  - Copied transcript-preprocessor.js"
fi

if [ -f "$SOURCE_UI_DIR/transcript-plugins.js" ]; then
    cp "$SOURCE_UI_DIR/transcript-plugins.js" ./
    log_info "  - Copied transcript-plugins.js"
fi

# Note: Viewer files are deployed separately via 426-deploy-viewer.sh

log_success "UI files copied"
echo ""

# Update audio.html with deployment values
log_info "Step 4: Updating audio.html configuration"

# Replace placeholders in audio.html
sed -i "s|TO_BE_REPLACED_USER_POOL_ID|$COGNITO_USER_POOL_ID|g" audio.html
sed -i "s|TO_BE_REPLACED_USER_POOL_CLIENT_ID|$COGNITO_USER_POOL_CLIENT_ID|g" audio.html
sed -i "s|TO_BE_REPLACED_IDENTITY_POOL_ID|$COGNITO_IDENTITY_POOL_ID|g" audio.html
sed -i "s|TO_BE_REPLACED_REGION|$AWS_REGION|g" audio.html
sed -i "s|TO_BE_REPLACED_AUDIO_API_URL|$COGNITO_API_ENDPOINT|g" audio.html
sed -i "s|TO_BE_REPLACED_APP_URL|$COGNITO_CLOUDFRONT_URL|g" audio.html

# Replace WhisperLive WebSocket URL (default to wss://EDGE_BOX_DNS/ws if not set)
WHISPERLIVE_WS_URL="${WHISPERLIVE_WS_URL:-wss://${EDGE_BOX_DNS:-localhost}/ws}"
sed -i "s|TO_BE_REPLACED_WHISPERLIVE_WS_URL|$WHISPERLIVE_WS_URL|g" audio.html

# Replace Google Doc ID (optional - only if configured)
if [ -n "${GOOGLE_DOC_ID:-}" ]; then
    sed -i "s|TO_BE_REPLACED_GOOGLE_DOC_ID|$GOOGLE_DOC_ID|g" audio.html
    log_info "  - Google Doc ID configured: $GOOGLE_DOC_ID"
else
    # Leave placeholder if not configured (will be detected as not configured in browser)
    log_info "  - Google Doc ID not configured (feature disabled)"
fi

log_success "Configuration updated in audio.html"
echo ""

# Update transcript-editor.html with deployment values
if [ -f "./transcript-editor.html" ]; then
    log_info "Step 4b: Updating transcript-editor.html configuration"

    # Replace placeholders in transcript-editor.html
    sed -i "s|TO_BE_REPLACED_USER_POOL_ID|$COGNITO_USER_POOL_ID|g" transcript-editor.html
    sed -i "s|TO_BE_REPLACED_USER_POOL_CLIENT_ID|$COGNITO_USER_POOL_CLIENT_ID|g" transcript-editor.html
    sed -i "s|TO_BE_REPLACED_IDENTITY_POOL_ID|$COGNITO_IDENTITY_POOL_ID|g" transcript-editor.html
    sed -i "s|TO_BE_REPLACED_REGION|$AWS_REGION|g" transcript-editor.html
    sed -i "s|TO_BE_REPLACED_API_URL|$COGNITO_API_ENDPOINT|g" transcript-editor.html
    sed -i "s|TO_BE_REPLACED_S3_API_URL|$COGNITO_API_ENDPOINT|g" transcript-editor.html
    sed -i "s|TO_BE_REPLACED_APP_URL|$COGNITO_CLOUDFRONT_URL|g" transcript-editor.html

    log_success "Configuration updated in transcript-editor.html"
    echo ""
else
    log_info "Step 4b: transcript-editor.html not found (skipping)"
    echo ""
fi

# Update transcript-editor-v2.html with deployment values
if [ -f "./transcript-editor-v2.html" ]; then
    log_info "Step 4c: Updating transcript-editor-v2.html configuration"

    # Replace placeholders in transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_USER_POOL_ID|$COGNITO_USER_POOL_ID|g" transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_USER_POOL_CLIENT_ID|$COGNITO_USER_POOL_CLIENT_ID|g" transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_IDENTITY_POOL_ID|$COGNITO_IDENTITY_POOL_ID|g" transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_REGION|$AWS_REGION|g" transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_API_URL|$COGNITO_API_ENDPOINT|g" transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_S3_API_URL|$COGNITO_API_ENDPOINT|g" transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_APP_URL|$COGNITO_CLOUDFRONT_URL|g" transcript-editor-v2.html
    sed -i "s|TO_BE_REPLACED_CLOUDFRONT_DOMAIN|${COGNITO_CLOUDFRONT_URL#https://}|g" transcript-editor-v2.html

    log_success "Configuration updated in transcript-editor-v2.html"
    echo ""
else
    log_info "Step 4c: transcript-editor-v2.html not found (skipping)"
    echo ""
fi

# Add logout button
log_info "Step 4c: Adding logout button to audio.html"

# Note: Test panel already removed from source audio.html

# Add logout button CSS to audio-ui-styles.css
cat >> audio-ui-styles.css << 'CSS_EOF'

/* Logout button */
.logout-button {
    position: fixed;
    top: 20px;
    right: 20px;
    padding: 10px 20px;
    background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
    color: white;
    border: none;
    border-radius: 6px;
    cursor: pointer;
    font-size: 14px;
    font-weight: 600;
    box-shadow: 0 4px 12px rgba(245, 87, 108, 0.3);
    transition: transform 0.2s, box-shadow 0.2s;
    z-index: 1000;
}

.logout-button:hover {
    transform: translateY(-2px);
    box-shadow: 0 6px 16px rgba(245, 87, 108, 0.4);
}

.logout-button:active {
    transform: translateY(0);
}
CSS_EOF

# Add logout button and authentication check to audio.html after <body>
sed -i '/<body>/a\    <button class="logout-button" id="logout-button">Sign Out</button>' audio.html

# Add authentication check script at the end of audio.html before </body>
# Use hardcoded client ID since config object is not accessible from regular script block
sed -i "/<\/body>/i\    <script>\
    \/\/ Authentication check for audio.html\
    window.addEventListener('DOMContentLoaded', function() {\
        const userPoolClientId = '${COGNITO_USER_POOL_CLIENT_ID}';\
        const keyPrefix = 'CognitoIdentityServiceProvider.' + userPoolClientId;\
        const lastAuthUser = localStorage.getItem(keyPrefix + '.LastAuthUser');\
        \
        if (!lastAuthUser) {\
            \/\/ Not authenticated - redirect to index\
            window.location.href = 'index.html';\
            return;\
        }\
        \
        const idToken = localStorage.getItem(keyPrefix + '.' + lastAuthUser + '.idToken');\
        if (!idToken) {\
            window.location.href = 'index.html';\
            return;\
        }\
        \
        \/\/ Check token expiry\
        try {\
            const payload = JSON.parse(atob(idToken.split('.')[1]));\
            const expiry = payload.exp * 1000;\
            if (Date.now() >= expiry) {\
                \/\/ Token expired\
                localStorage.removeItem(keyPrefix + '.LastAuthUser');\
                localStorage.removeItem(keyPrefix + '.' + lastAuthUser + '.idToken');\
                localStorage.removeItem(keyPrefix + '.' + lastAuthUser + '.accessToken');\
                window.location.href = 'index.html';\
                return;\
            }\
        } catch (error) {\
            console.error('Token validation error:', error);\
            window.location.href = 'index.html';\
            return;\
        }\
        \
        \/\/ Logout button handler (MOVED INSIDE DOMContentLoaded)\
        const logoutButton = document.getElementById('logout-button');\
        if (logoutButton) {\
            logoutButton.addEventListener('click', function() {\
                if (lastAuthUser) {\
                    localStorage.removeItem(keyPrefix + '.LastAuthUser');\
                    localStorage.removeItem(keyPrefix + '.' + lastAuthUser + '.idToken');\
                    localStorage.removeItem(keyPrefix + '.' + lastAuthUser + '.accessToken');\
                    localStorage.removeItem(keyPrefix + '.' + lastAuthUser + '.clockDrift');\
                }\
                \
                localStorage.removeItem('id_token');\
                localStorage.removeItem('access_token');\
                \
                window.location.href = 'index.html';\
            });\
        }\
    });\
    <\/script>" audio.html

log_success "Removed test panel and added logout button"
echo ""

# Regenerate app.js and callback.html with correct values (already have the fixed versions)
log_info "Step 5: Regenerating app.js and callback.html"

# Use app.js.template from source UI directory and replace configuration
log_info "  - Copying app.js.template with full file manager functionality"
if [ ! -f "$SOURCE_UI_DIR/app.js.template" ]; then
    log_error "app.js.template not found in $SOURCE_UI_DIR"
    exit 1
fi

cp "$SOURCE_UI_DIR/app.js.template" ./app.js

# Replace configuration placeholders in app.js
log_info "  - Replacing configuration placeholders"
sed -i "s|YOUR_USER_POOL_ID|${COGNITO_USER_POOL_ID}|g" app.js
sed -i "s|YOUR_CLIENT_ID|${COGNITO_USER_POOL_CLIENT_ID}|g" app.js
sed -i "s|YOUR_USER_POOL_CLIENT_ID|${COGNITO_USER_POOL_CLIENT_ID}|g" app.js
sed -i "s|YOUR_IDENTITY_POOL_ID|${COGNITO_IDENTITY_POOL_ID}|g" app.js
sed -i "s|YOUR_COGNITO_DOMAIN|${COGNITO_DOMAIN}|g" app.js
sed -i "s|YOUR_REGION|${AWS_REGION}|g" app.js
sed -i "s|YOUR_CLOUDFRONT_URL|${COGNITO_CLOUDFRONT_URL}|g" app.js
sed -i "s|YOUR_CLOUDFRONT_API_ENDPOINT|${COGNITO_API_ENDPOINT}|g" app.js
sed -i "s|YOUR_CLOUDFRONT_S3_API_ENDPOINT|${COGNITO_API_ENDPOINT}|g" app.js
sed -i "s|YOUR_APP_URL|${COGNITO_CLOUDFRONT_URL}|g" app.js
sed -i "s|YOUR_API_ENDPOINT|${COGNITO_API_ENDPOINT}|g" app.js
sed -i "s|YOUR_WHISPERLIVE_WS_URL|${WHISPERLIVE_WS_URL}|g" app.js
sed -i "s|YOUR_GOOGLE_DOC_ID|${GOOGLE_DOC_ID:-}|g" app.js

log_info "  - WhisperLive WebSocket URL: ${WHISPERLIVE_WS_URL}"
if [ -n "${GOOGLE_DOC_ID:-}" ]; then
    log_info "  - Google Doc ID: ${GOOGLE_DOC_ID}"
fi

# Note: app.js.template already has:
# - checkAuthentication() that shows dashboard-section when user is authenticated
# - showFileManager() that shows authenticated-section (file browser)
# - showDashboard() that shows dashboard-section
# - All S3 file operations (listS3Files, uploadFile, downloadFile, etc.)

# Now continue with minimal custom app.js generation for backward compatibility
# (This section will be removed - keeping for reference only)
cat > /dev/null << 'EOL'

// Initialize Cognito
const poolData = {
    UserPoolId: userPoolId,
    ClientId: userPoolClientId
};

const userPool = new AmazonCognitoIdentity.CognitoUserPool(poolData);

// Check if user is already logged in
window.addEventListener('DOMContentLoaded', function() {
    // Check localStorage directly for tokens from Hosted UI
    const keyPrefix = `CognitoIdentityServiceProvider.${userPoolClientId}`;
    const lastAuthUser = localStorage.getItem(`${keyPrefix}.LastAuthUser`);
    
    console.log('Checking authentication:', {
        lastAuthUser: lastAuthUser,
        hasIdToken: !!lastAuthUser && !!localStorage.getItem(`${keyPrefix}.${lastAuthUser}.idToken`)
    });

    if (lastAuthUser) {
        const idToken = localStorage.getItem(`${keyPrefix}.${lastAuthUser}.idToken`);
        
        if (idToken) {
            try {
                // Decode and validate token
                const payload = JSON.parse(atob(idToken.split('.')[1]));
                const expiry = payload.exp * 1000;
                
                console.log('Token expiry:', new Date(expiry), 'Current time:', new Date());
                
                if (Date.now() < expiry) {
                    // Token is valid - show dashboard if on index page
                    console.log('Token is valid, user authenticated');
                    if (window.location.pathname.endsWith('index.html') || window.location.pathname === '/') {
                        if (document.getElementById('login-section')) {
                            document.getElementById('login-section').style.display = 'none';
                        }
                        if (document.getElementById('dashboard-section')) {
                            document.getElementById('dashboard-section').style.display = 'block';
                        }
                        if (document.getElementById('authenticated-section')) {
                            document.getElementById('authenticated-section').style.display = 'none';
                        }
                    }
                    return; // Exit early - user is authenticated
                } else {
                    console.log('Token expired, clearing localStorage');
                    // Clear expired tokens
                    localStorage.removeItem(`${keyPrefix}.LastAuthUser`);
                    localStorage.removeItem(`${keyPrefix}.${lastAuthUser}.idToken`);
                    localStorage.removeItem(`${keyPrefix}.${lastAuthUser}.accessToken`);
                    localStorage.removeItem(`${keyPrefix}.${lastAuthUser}.clockDrift`);
                }
            } catch (error) {
                console.error('Error validating token:', error);
            }
        }
    }

    // Not authenticated - show login section if on index page
    if (window.location.pathname.endsWith('index.html') || window.location.pathname === '/') {
        console.log('User not authenticated, showing login');
        if (document.getElementById('login-section')) {
            document.getElementById('login-section').style.display = 'block';
        }
        if (document.getElementById('dashboard-section')) {
            document.getElementById('dashboard-section').style.display = 'none';
        }
        if (document.getElementById('authenticated-section')) {
            document.getElementById('authenticated-section').style.display = 'none';
        }
    }
});

// Sign in button
if (document.getElementById('login-button')) {
    document.getElementById('login-button').addEventListener('click', function() {
        const authUrl = `https://${cognitoDomain}.auth.${region}.amazoncognito.com/login?response_type=token&client_id=${userPoolClientId}&redirect_uri=${cloudFrontUrl}/callback.html`;
        window.location.href = authUrl;
    });
}

// Sign out button
if (document.getElementById('logout-button')) {
    document.getElementById('logout-button').addEventListener('click', function() {
        // Clear tokens from localStorage
        const keyPrefix = `CognitoIdentityServiceProvider.${userPoolClientId}`;
        const lastAuthUser = localStorage.getItem(`${keyPrefix}.LastAuthUser`);
        
        if (lastAuthUser) {
            localStorage.removeItem(`${keyPrefix}.LastAuthUser`);
            localStorage.removeItem(`${keyPrefix}.${lastAuthUser}.idToken`);
            localStorage.removeItem(`${keyPrefix}.${lastAuthUser}.accessToken`);
            localStorage.removeItem(`${keyPrefix}.${lastAuthUser}.clockDrift`);
        }
        
        localStorage.removeItem('id_token');
        localStorage.removeItem('access_token');
        
        window.location.href = cloudFrontUrl + '/index.html';
    });
}

// Test Lambda API button
if (document.getElementById('get-data-button')) {
    document.getElementById('get-data-button').addEventListener('click', function() {
        const keyPrefix = `CognitoIdentityServiceProvider.${userPoolClientId}`;
        const lastAuthUser = localStorage.getItem(`${keyPrefix}.LastAuthUser`);
        
        if (lastAuthUser) {
            const idToken = localStorage.getItem(`${keyPrefix}.${lastAuthUser}.idToken`);
            
            if (idToken) {
                fetch(apiEndpoint, {
                    method: 'GET',
                    headers: {
                        'Authorization': idToken
                    }
                })
                .then(response => response.json())
                .then(data => {
                    document.getElementById('data-output').textContent = JSON.stringify(data, null, 2);
                })
                .catch(error => {
                    console.error('API error:', error);
                    document.getElementById('data-output').textContent = 'Error: ' + error.message;
                });
            }
        }
    });
}
EOL

# Generate callback.html
cat > callback.html << EOL
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Authentication Callback</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <div class="container">
        <h1>Processing Authentication...</h1>
        <p>Please wait while we process your sign-in.</p>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/amazon-cognito-identity-js/dist/amazon-cognito-identity.min.js"></script>
    <script>
        // Configuration
        const userPoolId = '${COGNITO_USER_POOL_ID}';
        const userPoolClientId = '${COGNITO_USER_POOL_CLIENT_ID}';

        // Parse the URL fragment for tokens (implicit flow)
        const fragment = window.location.hash.substring(1);
        const params = new URLSearchParams(fragment);

        const idToken = params.get('id_token');
        const accessToken = params.get('access_token');

        console.log('Tokens received:', { hasIdToken: !!idToken, hasAccessToken: !!accessToken });

        if (idToken && accessToken) {
            try {
                // Decode the id_token to get the username (sub claim)
                const payload = JSON.parse(atob(idToken.split('.')[1]));
                const username = payload['cognito:username'] || payload['sub'];

                console.log('Decoded username:', username);

                // Store tokens in BOTH formats:
                // 1. Plain format for React app compatibility
                localStorage.setItem('id_token', idToken);
                localStorage.setItem('access_token', accessToken);

                // 2. Cognito SDK format for auth checks
                const keyPrefix = \`CognitoIdentityServiceProvider.\${userPoolClientId}\`;
                const userPrefix = \`\${keyPrefix}.\${username}\`;

                localStorage.setItem(\`\${keyPrefix}.LastAuthUser\`, username);
                localStorage.setItem(\`\${userPrefix}.idToken\`, idToken);
                localStorage.setItem(\`\${userPrefix}.accessToken\`, accessToken);
                localStorage.setItem(\`\${userPrefix}.clockDrift\`, '0');

                console.log('Tokens stored successfully for user:', username);
            } catch (error) {
                console.error('Error processing tokens:', error);
            }
        } else {
            console.error('No tokens found in URL fragment');
        }

        // Redirect to dashboard (user is authenticated)
        window.location.href = 'index.html';
    </script>
</body>
</html>
EOL

log_success "app.js and callback.html generated"
echo ""

# Upload to S3
log_info "Step 6: Uploading files to S3"
aws s3 cp . "s3://$COGNITO_S3_BUCKET/" --recursive --exclude ".git/*" --exclude "*.bak"
log_success "Files uploaded to S3"
echo ""

# Invalidate CloudFront
log_info "Step 7: Invalidating CloudFront cache"
DISTRIBUTION_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?DomainName=='$(echo $COGNITO_CLOUDFRONT_URL | sed 's|https://||')'].Id" \
    --output text)

if [ -n "$DISTRIBUTION_ID" ] && [ "$DISTRIBUTION_ID" != "None" ]; then
    aws cloudfront create-invalidation \
        --distribution-id "$DISTRIBUTION_ID" \
        --paths "/*" &> /dev/null
    log_success "CloudFront cache invalidated"
else
    log_warn "⚠️  Could not determine CloudFront distribution ID"
fi
echo ""

# Success reporting
echo ""
log_info "==================================================================="
log_success "✅ RECORDER UI DEPLOYED SUCCESSFULLY"
log_info "==================================================================="
echo ""
log_info "🔗 Application URL:"
log_info "  - $COGNITO_CLOUDFRONT_URL"
echo ""
log_info "📋 Features Deployed:"
log_info "  - Full audio recorder UI"
log_info "  - Cognito authentication"
log_info "  - Session management"
log_info "  - Audio chunk upload/download"
echo ""
log_info "⚠️  Note:"
log_info "  - CloudFront cache may take 1-2 minutes to propagate"
log_info "  - First load may take longer due to React loading"
echo ""
log_info "Next Steps:"
log_info "  1. Visit $COGNITO_CLOUDFRONT_URL"
log_info "  2. Sign in with your Cognito credentials"
log_info "  3. You'll be redirected to audio.html (recorder page)"
log_info "  4. Test the recorder functionality"
echo ""
