#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 420: Deploy Cognito/S3/Lambda Stack
# ============================================================================
# Deploys the serverless CloudFormation stack with Cognito authentication,
# S3 website hosting, CloudFront CDN, and Lambda functions.
#
# What this does:
# 1. Validates prerequisites (script 410 completed, AWS credentials)
# 2. Installs Node.js dependencies (serverless framework)
# 3. Deploys CloudFormation stack using serverless deploy
# 4. Retrieves deployment outputs (resource IDs, endpoints, URLs)
# 5. Configures Cognito User Pool Client callback URLs
# 6. Creates Cognito domain prefix
# 7. Updates .env with deployed resource information
# 8. Creates app.js from template with actual configuration
# 9. Uploads web files to S3
# 10. Creates CloudFront cache invalidation
#
# Requirements:
# - Script 410 completed successfully
# - AWS CLI configured with proper credentials
# - Node.js and npm installed
#
# Total time: ~10-15 minutes (CloudFormation stack creation is slow)
# ============================================================================

# Find repository root (works from symlink or direct execution)
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_REAL=$(readlink -f "${BASH_SOURCE[0]}")
else
    SCRIPT_REAL="${BASH_SOURCE[0]}"
fi
REPO_ROOT="$(cd "$(dirname "$SCRIPT_REAL")/.." && pwd)"

source "$REPO_ROOT/scripts/lib/common-functions.sh"
load_environment

echo "============================================"
echo "420: Deploy Cognito/S3/Lambda Stack"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Install Node.js dependencies"
log_info "  2. Deploy CloudFormation stack (~10-15 minutes)"
log_info "  3. Configure Cognito resources"
log_info "  4. Upload web files to S3"
log_info "  5. Update .env with deployment outputs"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Validating prerequisites"
# Validate required .env variables
if [ -z "${COGNITO_APP_NAME:-}" ] || [ -z "${COGNITO_STAGE:-}" ] || [ -z "${COGNITO_S3_BUCKET:-}" ] || [ -z "${COGNITO_DOMAIN:-}" ]; then
    log_error "❌ Missing required Cognito variables in .env"
    log_error "Please run ./scripts/410-questions-setup-cognito-s3-lambda.sh first"
    exit 1
fi

# Check cognito-stack directory exists
COGNITO_DIR="$REPO_ROOT/cognito-stack"
if [ ! -d "$COGNITO_DIR" ]; then
    log_error "❌ cognito-stack directory not found"
    log_error "Please run ./scripts/410-questions-setup-cognito-s3-lambda.sh first"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "❌ AWS credentials not configured. Run 'aws configure' first"
    exit 1
fi

log_success "Prerequisites validated"
echo ""

# Change to cognito-stack directory
cd "$COGNITO_DIR"

log_info "Step 2: Installing Node.js dependencies"
if [ ! -d "node_modules" ]; then
    log_info "Installing serverless framework and dependencies..."
    npm install --legacy-peer-deps
    log_success "Dependencies installed"
else
    log_info "Dependencies already installed"
fi
echo ""

log_info "Step 3: Deploying CloudFormation stack"
log_warn "⚠️  This may take 10-15 minutes as CloudFormation creates all resources"
echo ""
npx serverless deploy --stage "$COGNITO_STAGE"
echo ""
log_success "Stack deployed successfully"
echo ""

log_info "Step 4: Retrieving deployment outputs"
export AWS_PAGER=""
STACK_NAME="${COGNITO_APP_NAME}-${COGNITO_STAGE}"

USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
    --output text)

USER_POOL_CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" \
    --output text)

IDENTITY_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='IdentityPoolId'].OutputValue" \
    --output text)

API_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" \
    --output text)

WEBSITE_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue" \
    --output text)

CLOUDFRONT_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" \
    --output text)

log_success "Retrieved deployment outputs"
log_info "  - User Pool ID: $USER_POOL_ID"
log_info "  - CloudFront URL: $CLOUDFRONT_URL"
echo ""

log_info "Step 5: Configuring Cognito User Pool Client"
log_info "Updating callback and logout URLs to use CloudFront..."
aws cognito-idp update-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-id "$USER_POOL_CLIENT_ID" \
    --callback-urls "${CLOUDFRONT_URL}/callback.html" \
    --logout-urls "${CLOUDFRONT_URL}/index.html" \
    --allowed-o-auth-flows "code" "implicit" \
    --allowed-o-auth-scopes "email" "openid" "profile" \
    --supported-identity-providers "COGNITO" \
    --allowed-o-auth-flows-user-pool-client &> /dev/null

log_success "Cognito User Pool Client updated"
echo ""

log_info "Step 6: Setting up Cognito domain"
# Check if domain already exists for this user pool
DOMAIN_CHECK=$(aws cognito-idp describe-user-pool \
    --user-pool-id "$USER_POOL_ID" \
    --query "UserPool.Domain" \
    --output text 2>/dev/null || echo "None")

if [ "$DOMAIN_CHECK" = "None" ] || [ -z "$DOMAIN_CHECK" ]; then
    log_info "Creating new Cognito domain: $COGNITO_DOMAIN"
    aws cognito-idp create-user-pool-domain \
        --domain "$COGNITO_DOMAIN" \
        --user-pool-id "$USER_POOL_ID"
    log_success "Cognito domain created: ${COGNITO_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com"
else
    log_info "Using existing Cognito domain: $DOMAIN_CHECK"
    COGNITO_DOMAIN="$DOMAIN_CHECK"
fi
echo ""

log_info "Step 7: Invoking custom resource Lambda"
FUNCTION_NAME="${COGNITO_APP_NAME}-${COGNITO_STAGE}-setIdentityPoolRoles"
log_info "Triggering setIdentityPoolRoles Lambda function..."
if aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --invocation-type Event \
    /dev/null &> /dev/null; then
    log_success "Lambda function invoked successfully"
else
    log_warn "⚠️  Lambda invocation failed (this is sometimes expected)"
fi
echo ""

log_info "Step 8: Updating .env with deployment outputs"
cd "$REPO_ROOT"

# Update .env file with deployed resource IDs
if grep -q "^COGNITO_USER_POOL_ID=" .env; then
    sed -i.bak "s|^COGNITO_USER_POOL_ID=.*$|COGNITO_USER_POOL_ID=$USER_POOL_ID|" .env
else
    sed -i.bak "/^COGNITO_DOMAIN=/a COGNITO_USER_POOL_ID=$USER_POOL_ID" .env
fi

if grep -q "^COGNITO_USER_POOL_CLIENT_ID=" .env; then
    sed -i.bak "s|^COGNITO_USER_POOL_CLIENT_ID=.*$|COGNITO_USER_POOL_CLIENT_ID=$USER_POOL_CLIENT_ID|" .env
else
    sed -i.bak "/^COGNITO_USER_POOL_ID=/a COGNITO_USER_POOL_CLIENT_ID=$USER_POOL_CLIENT_ID" .env
fi

if grep -q "^COGNITO_IDENTITY_POOL_ID=" .env; then
    sed -i.bak "s|^COGNITO_IDENTITY_POOL_ID=.*$|COGNITO_IDENTITY_POOL_ID=$IDENTITY_POOL_ID|" .env
else
    sed -i.bak "/^COGNITO_USER_POOL_CLIENT_ID=/a COGNITO_IDENTITY_POOL_ID=$IDENTITY_POOL_ID" .env
fi

if grep -q "^COGNITO_API_ENDPOINT=" .env; then
    sed -i.bak "s|^COGNITO_API_ENDPOINT=.*$|COGNITO_API_ENDPOINT=$API_ENDPOINT|" .env
else
    sed -i.bak "/^COGNITO_IDENTITY_POOL_ID=/a COGNITO_API_ENDPOINT=$API_ENDPOINT" .env
fi

if grep -q "^COGNITO_CLOUDFRONT_URL=" .env; then
    sed -i.bak "s|^COGNITO_CLOUDFRONT_URL=.*$|COGNITO_CLOUDFRONT_URL=$CLOUDFRONT_URL|" .env
else
    sed -i.bak "/^COGNITO_API_ENDPOINT=/a COGNITO_CLOUDFRONT_URL=$CLOUDFRONT_URL" .env
fi

log_success "Updated .env with deployment outputs"
echo ""

log_info "Step 9: Creating app.js with deployment configuration"
cd "$COGNITO_DIR"

# Create app.js with actual deployment values
cat > web/app.js << EOL
// WARNING: THIS FILE IS AUTO-GENERATED BY THE DEPLOYMENT SCRIPT.
// DO NOT EDIT DIRECTLY AS YOUR CHANGES WILL BE OVERWRITTEN.
// This file is generated by script 420-deploy-cognito-stack.sh

// AWS Cognito Configuration
const userPoolId = '${USER_POOL_ID}';
const userPoolClientId = '${USER_POOL_CLIENT_ID}';
const identityPoolId = '${IDENTITY_POOL_ID}';
const apiEndpoint = '${API_ENDPOINT}';
const cognitoDomain = '${COGNITO_DOMAIN}';
const region = '${AWS_REGION}';
const cloudFrontUrl = '${CLOUDFRONT_URL}';

// Initialize Cognito
const poolData = {
    UserPoolId: userPoolId,
    ClientId: userPoolClientId
};

const userPool = new AmazonCognitoIdentity.CognitoUserPool(poolData);

// Check if user is already logged in
window.addEventListener('DOMContentLoaded', function() {
    const cognitoUser = userPool.getCurrentUser();

    if (cognitoUser != null) {
        cognitoUser.getSession(function(err, session) {
            if (err) {
                console.error('Session error:', err);
                document.getElementById('login-section').style.display = 'block';
                document.getElementById('authenticated-section').style.display = 'none';
                return;
            }

            console.log('Session valid:', session.isValid());

            if (session.isValid()) {
                // User is authenticated
                cognitoUser.getUserAttributes(function(err, attributes) {
                    if (err) {
                        console.error('Error getting attributes:', err);
                        return;
                    }

                    const emailAttribute = attributes.find(attr => attr.Name === 'email');
                    if (emailAttribute) {
                        document.getElementById('user-email').textContent = emailAttribute.Value;
                    }

                    document.getElementById('login-section').style.display = 'none';
                    document.getElementById('authenticated-section').style.display = 'block';
                });
            } else {
                document.getElementById('login-section').style.display = 'block';
                document.getElementById('authenticated-section').style.display = 'none';
            }
        });
    } else {
        document.getElementById('login-section').style.display = 'block';
        document.getElementById('authenticated-section').style.display = 'none';
    }
});

// Sign in button
document.getElementById('login-button').addEventListener('click', function() {
    const authUrl = \`https://\${cognitoDomain}.auth.\${region}.amazoncognito.com/login?response_type=token&client_id=\${userPoolClientId}&redirect_uri=\${cloudFrontUrl}/callback.html\`;
    window.location.href = authUrl;
});

// Sign out button
document.getElementById('logout-button').addEventListener('click', function() {
    const cognitoUser = userPool.getCurrentUser();
    if (cognitoUser) {
        cognitoUser.signOut();
    }
    window.location.href = cloudFrontUrl + '/index.html';
});

// Test Lambda API button
document.getElementById('get-data-button').addEventListener('click', function() {
    const cognitoUser = userPool.getCurrentUser();

    if (cognitoUser) {
        cognitoUser.getSession(function(err, session) {
            if (err) {
                console.error('Session error:', err);
                document.getElementById('data-output').textContent = 'Error: ' + err.message;
                return;
            }

            const idToken = session.getIdToken().getJwtToken();

            // Call Lambda API
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
        });
    }
});
EOL

log_success "Created web/app.js with deployment configuration"
echo ""

log_info "Step 10: Uploading web files to S3"
aws s3 cp web/ "s3://$COGNITO_S3_BUCKET/" --recursive
log_success "Web files uploaded to S3"
echo ""

log_info "Step 11: Creating CloudFront cache invalidation"
DISTRIBUTION_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?DomainName=='$(echo $CLOUDFRONT_URL | sed 's|https://||')'].Id" \
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

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ COGNITO/S3/LAMBDA STACK DEPLOYED SUCCESSFULLY"
log_info "==================================================================="
echo ""
log_info "🔗 Website URLs:"
log_info "  - CloudFront: $CLOUDFRONT_URL"
log_info "  - S3 Website: $WEBSITE_URL"
echo ""
log_info "📋 Application Details:"
log_info "  - API Endpoint: $API_ENDPOINT"
log_info "  - User Pool ID: $USER_POOL_ID"
log_info "  - User Pool Client ID: $USER_POOL_CLIENT_ID"
log_info "  - Identity Pool ID: $IDENTITY_POOL_ID"
log_info "  - Cognito Domain: ${COGNITO_DOMAIN}.auth.${AWS_REGION}.amazoncognito.com"
echo ""
log_info "⚠️  Important Notes:"
log_info "  - CloudFront distribution may take 5-10 minutes to fully deploy"
log_info "  - Cognito domain DNS propagation may take 15-30 minutes"
log_info "  - You must create a user before testing authentication"
echo ""
log_info "Next Steps:"
log_info "  1. Create a test user: ./scripts/430-create-cognito-user.sh"
log_info "  2. Test the application: Open $CLOUDFRONT_URL in your browser"
log_info "  3. (Optional) Update web files: ./scripts/425-update-web-files.sh"
echo ""
log_info "⚠️  DO NOT commit web/app.js to version control (contains environment-specific values)"
echo ""
