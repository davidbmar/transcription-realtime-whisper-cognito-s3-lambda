#!/bin/bash
set -euo pipefail
exec > >(tee -a "logs/$(basename $0 .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

# ============================================================================
# Script 410: Setup Cognito/S3/Lambda Infrastructure
# ============================================================================
# Interactive setup script for serverless authentication and web hosting.
# Creates a complete CloudFormation stack with Cognito User Pool, Identity Pool,
# S3 bucket for website hosting, CloudFront distribution, and Lambda functions.
#
# What this does:
# 1. Validates AWS CLI installation and credentials
# 2. Prompts for application name, S3 bucket, Cognito domain, and stage
# 3. Generates serverless.yml with complete CloudFormation resources
# 4. Creates package.json for Node.js dependencies
# 5. Creates Lambda handler functions (API Gateway + custom resources)
# 6. Creates web application files (HTML, CSS, JS templates)
# 7. Updates .env with Cognito/S3/Lambda configuration
# 8. Updates .gitignore for generated files
#
# Requirements:
# - .env variables: AWS_REGION, AWS_ACCOUNT_ID
# - AWS CLI installed and configured
# - Node.js installed (for serverless framework)
#
# Total time: ~2 minutes
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
echo "410: Setup Cognito/S3/Lambda Infrastructure"
echo "============================================"
echo ""

log_info "This script will:"
log_info "  1. Validate AWS CLI and credentials"
log_info "  2. Prompt for application configuration"
log_info "  3. Generate serverless.yml CloudFormation stack"
log_info "  4. Create Lambda function handlers"
log_info "  5. Create web application files"
log_info "  6. Update .env with Cognito configuration"
echo ""

# ============================================================================
# Main Implementation
# ============================================================================

log_info "Step 1: Validating AWS CLI installation"
if ! command -v aws &> /dev/null; then
    log_error "❌ AWS CLI is not installed. Please install it first:"
    echo "   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi
log_success "AWS CLI installed"
echo ""

log_info "Step 2: Validating AWS credentials"
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "❌ AWS CLI is not configured properly. Please run 'aws configure' first."
    exit 1
fi
log_success "AWS credentials validated"
echo ""

# Get configuration from existing .env
log_info "Step 3: Loading existing configuration"
REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

log_info "AWS Region: $REGION"
log_info "AWS Account ID: $ACCOUNT_ID"
echo ""

# Generate unique app name with username prefix
log_info "Step 4: Configuring application name"
DEFAULT_USERNAME=$(whoami | tr -cd '[:alnum:]-' | tr '[:upper:]' '[:lower:]')
if [ -z "$DEFAULT_USERNAME" ]; then
    DEFAULT_USERNAME="user"
fi
DEFAULT_APP_NAME="${DEFAULT_USERNAME}-transcription-cognito"

echo ""
log_info "⚠️  The application name will be used for the CloudFormation stack and resource naming."
echo ""
read -p "Enter application name (or press Enter for default '$DEFAULT_APP_NAME'): " APP_NAME
APP_NAME=${APP_NAME:-$DEFAULT_APP_NAME}

# Validate app name
if [[ ! $APP_NAME =~ ^[a-zA-Z0-9-]+$ ]]; then
    log_error "❌ Invalid application name. Please use only letters, numbers, and hyphens."
    exit 1
fi

log_success "Using application name: $APP_NAME"
echo ""

# Generate unique bucket name
log_info "Step 5: Configuring S3 bucket for website hosting"
TIMESTAMP=$(date +%s)
DEFAULT_BUCKET_NAME="${APP_NAME}-website-${TIMESTAMP}-${ACCOUNT_ID}"

echo ""
log_info "⚠️  S3 bucket names must be globally unique across all of AWS."
log_info "⚠️  Bucket names must only use lowercase letters, numbers, hyphens, and periods."
echo ""
read -p "Enter S3 bucket name (or press Enter for default '$DEFAULT_BUCKET_NAME'): " BUCKET_NAME
BUCKET_NAME=${BUCKET_NAME:-$DEFAULT_BUCKET_NAME}

# Validate bucket name
if [[ ! $BUCKET_NAME =~ ^[a-z0-9.-]+$ ]]; then
    log_error "❌ Invalid bucket name. Please use only lowercase letters, numbers, hyphens, and periods."
    exit 1
fi

log_success "Using bucket name: $BUCKET_NAME"
echo ""

# Generate unique Cognito domain name
log_info "Step 6: Configuring Cognito domain"
DEFAULT_COGNITO_DOMAIN="${APP_NAME}-${TIMESTAMP}"

echo ""
log_info "⚠️  Cognito domain naming restrictions:"
log_info "  - Must use only lowercase letters, numbers, and hyphens"
log_info "  - Cannot contain the word 'cognito' or 'aws' (reserved words)"
log_info "  - Between 1-63 characters"
echo ""

# Loop until we get a valid domain name
while true; do
    read -p "Enter Cognito domain prefix (or press Enter for default '$DEFAULT_COGNITO_DOMAIN'): " COGNITO_DOMAIN
    COGNITO_DOMAIN=${COGNITO_DOMAIN:-$DEFAULT_COGNITO_DOMAIN}

    # Validate domain name
    if [[ ! $COGNITO_DOMAIN =~ ^[a-z0-9-]+$ ]]; then
        log_error "❌ Invalid domain name. Please use only lowercase letters, numbers, and hyphens."
        continue
    fi

    # Check for reserved words
    if [[ $COGNITO_DOMAIN == *cognito* || $COGNITO_DOMAIN == *aws* ]]; then
        log_error "❌ Domain name cannot contain reserved words 'cognito' or 'aws'. Please choose another name."
        continue
    fi

    # Check length
    if [ ${#COGNITO_DOMAIN} -gt 63 ]; then
        log_error "❌ Domain name is too long. Maximum length is 63 characters."
        continue
    fi

    # Valid domain
    break
done

log_success "Using Cognito domain: $COGNITO_DOMAIN"
echo ""

# Generate application stage
log_info "Step 7: Configuring deployment stage"
DEFAULT_STAGE="dev"
read -p "Enter deployment stage (or press Enter for default '$DEFAULT_STAGE'): " STAGE
STAGE=${STAGE:-$DEFAULT_STAGE}

# Validate stage
if [[ ! $STAGE =~ ^[a-zA-Z0-9-]+$ ]]; then
    log_error "❌ Invalid stage name. Please use only letters, numbers, and hyphens."
    exit 1
fi

log_success "Using deployment stage: $STAGE"
echo ""

# Create cognito-stack directory if it doesn't exist
log_info "Step 8: Creating project directory structure"
COGNITO_DIR="$REPO_ROOT/cognito-stack"
mkdir -p "$COGNITO_DIR"
cd "$COGNITO_DIR"
log_success "Created directory: $COGNITO_DIR"
echo ""

# Create package.json if it doesn't exist
log_info "Step 9: Generating package.json"
cat > package.json << EOL
{
  "name": "${APP_NAME}",
  "version": "1.0.0",
  "description": "Cognito/S3/Lambda serverless authentication stack for transcription app",
  "main": "index.js",
  "scripts": {
    "deploy": "serverless deploy",
    "remove": "serverless remove"
  },
  "devDependencies": {
    "serverless": "^3.30.1"
  },
  "dependencies": {
    "aws-sdk": "^2.1423.0"
  }
}
EOL
log_success "Created package.json"
echo ""

# Create serverless.yml
log_info "Step 10: Generating serverless.yml CloudFormation template"
cat > serverless.yml << EOL
service: ${APP_NAME}

provider:
  name: aws
  runtime: nodejs18.x
  region: ${REGION}
  iam:
    role:
      statements:
        - Effect: Allow
          Action:
            - s3:GetObject
          Resource: "arn:aws:s3:::#{WebsiteBucket}/*"
        - Effect: Allow
          Action:
            - cognito-identity:SetIdentityPoolRoles
          Resource: "*"
        - Effect: Allow
          Action:
            - iam:PassRole
          Resource: !GetAtt AuthenticatedRole.Arn

custom:
  s3Bucket: ${BUCKET_NAME}

functions:
  api:
    handler: api/handler.getData
    events:
      - http:
          path: data
          method: get
          cors: true
          authorizer:
            type: COGNITO_USER_POOLS
            authorizerId:
              Ref: ApiGatewayAuthorizer

  # Custom resource function to set identity pool roles
  setIdentityPoolRoles:
    handler: functions/setIdentityPoolRoles.handler
    environment:
      IDENTITY_POOL_ID: !Ref IdentityPool
      AUTHENTICATED_ROLE_ARN: !GetAtt AuthenticatedRole.Arn

resources:
  Resources:
    # API Gateway Authorizer
    ApiGatewayAuthorizer:
      Type: AWS::ApiGateway::Authorizer
      Properties:
        Name: cognito-authorizer
        IdentitySource: method.request.header.Authorization
        RestApiId:
          Ref: ApiGatewayRestApi
        Type: COGNITO_USER_POOLS
        ProviderARNs:
          - !GetAtt UserPool.Arn

    # S3 bucket for website hosting with public access
    WebsiteBucket:
      Type: AWS::S3::Bucket
      Properties:
        BucketName: ${BUCKET_NAME}
        WebsiteConfiguration:
          IndexDocument: index.html
          ErrorDocument: error.html
        PublicAccessBlockConfiguration:
          BlockPublicAcls: false
          BlockPublicPolicy: false
          IgnorePublicAcls: false
          RestrictPublicBuckets: false
        CorsConfiguration:
          CorsRules:
            - AllowedHeaders: ['*']
              AllowedMethods: [GET, HEAD, PUT]
              AllowedOrigins: ['*']
              MaxAge: 3000

    # Cognito user pool
    UserPool:
      Type: AWS::Cognito::UserPool
      Properties:
        UserPoolName: ${APP_NAME}-user-pool-${STAGE}
        AutoVerifiedAttributes:
          - email
        UsernameAttributes:
          - email
        Policies:
          PasswordPolicy:
            MinimumLength: 8
            RequireLowercase: true
            RequireNumbers: true
            RequireSymbols: false
            RequireUppercase: true

    # Cognito user pool client
    UserPoolClient:
      Type: AWS::Cognito::UserPoolClient
      Properties:
        ClientName: ${APP_NAME}-app-client-${STAGE}
        UserPoolId: !Ref UserPool
        GenerateSecret: false
        ExplicitAuthFlows:
          - ALLOW_USER_SRP_AUTH
          - ALLOW_REFRESH_TOKEN_AUTH
        AllowedOAuthFlowsUserPoolClient: true
        AllowedOAuthFlows:
          - implicit
          - code
        AllowedOAuthScopes:
          - email
          - openid
          - profile
        CallbackURLs:
          - 'http://localhost:8080/callback.html'
        LogoutURLs:
          - 'http://localhost:8080/index.html'
        SupportedIdentityProviders:
          - COGNITO

    # Cognito identity pool
    IdentityPool:
      Type: AWS::Cognito::IdentityPool
      Properties:
        IdentityPoolName: ${APP_NAME}-identity-pool-${STAGE}
        AllowUnauthenticatedIdentities: false
        CognitoIdentityProviders:
          - ClientId: !Ref UserPoolClient
            ProviderName: !GetAtt UserPool.ProviderName

    # IAM roles for authenticated users
    AuthenticatedRole:
      Type: AWS::IAM::Role
      Properties:
        AssumeRolePolicyDocument:
          Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Principal:
                Federated: cognito-identity.amazonaws.com
              Action: sts:AssumeRoleWithWebIdentity
              Condition:
                StringEquals:
                  cognito-identity.amazonaws.com:aud: !Ref IdentityPool
                ForAnyValue:StringLike:
                  cognito-identity.amazonaws.com:amr: authenticated
        ManagedPolicyArns:
          - arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

    # Custom resource to set identity pool roles after creation
    SetRolesCustomResource:
      Type: Custom::SetIdentityPoolRoles
      DependsOn:
        - IdentityPool
        - AuthenticatedRole
      Properties:
        ServiceToken: !GetAtt SetIdentityPoolRolesLambdaFunction.Arn
        IdentityPoolId: !Ref IdentityPool
        Roles:
          authenticated: !GetAtt AuthenticatedRole.Arn

    CloudFrontDistribution:
      Type: AWS::CloudFront::Distribution
      Properties:
        DistributionConfig:
          Origins:
            - DomainName: !GetAtt WebsiteBucket.DomainName
              Id: S3Origin
              S3OriginConfig:
                OriginAccessIdentity: !Sub "origin-access-identity/cloudfront/\${CloudFrontOriginAccessIdentity}"
          Enabled: true
          DefaultRootObject: index.html
          DefaultCacheBehavior:
            AllowedMethods:
              - GET
              - HEAD
            TargetOriginId: S3Origin
            ForwardedValues:
              QueryString: false
              Cookies:
                Forward: none
            ViewerProtocolPolicy: redirect-to-https
          CustomErrorResponses:
            - ErrorCode: 403
              ResponsePagePath: /index.html
              ResponseCode: 200
              ErrorCachingMinTTL: 10
            - ErrorCode: 404
              ResponsePagePath: /index.html
              ResponseCode: 200
              ErrorCachingMinTTL: 10
          ViewerCertificate:
            CloudFrontDefaultCertificate: true

    CloudFrontOriginAccessIdentity:
      Type: AWS::CloudFront::CloudFrontOriginAccessIdentity
      Properties:
        CloudFrontOriginAccessIdentityConfig:
          Comment: "Access identity for S3 bucket"

    # Update the bucket policy to grant CloudFront access
    WebsiteBucketPolicy:
      Type: AWS::S3::BucketPolicy
      Properties:
        Bucket: !Ref WebsiteBucket
        PolicyDocument:
          Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Principal:
                CanonicalUser: !GetAtt CloudFrontOriginAccessIdentity.S3CanonicalUserId
              Action: 's3:GetObject'
              Resource: !Join ['', ['arn:aws:s3:::', !Ref WebsiteBucket, '/*']]

  Outputs:
    WebsiteURL:
      Description: S3 Website URL
      Value: !GetAtt WebsiteBucket.WebsiteURL
    WebsiteBucketName:
      Description: Name of the S3 bucket for website hosting
      Value: !Ref WebsiteBucket
    ApiEndpoint:
      Description: URL of the API Gateway endpoint
      Value: !Sub "https://\${ApiGatewayRestApi}.execute-api.\${AWS::Region}.amazonaws.com/\${sls:stage}/data"
    UserPoolId:
      Description: ID of the Cognito User Pool
      Value: !Ref UserPool
    UserPoolClientId:
      Description: ID of the Cognito User Pool Client
      Value: !Ref UserPoolClient
    IdentityPoolId:
      Description: ID of the Cognito Identity Pool
      Value: !Ref IdentityPool
    CloudFrontURL:
      Description: URL of the CloudFront distribution
      Value: !Sub "https://\${CloudFrontDistribution.DomainName}"
EOL
log_success "Created serverless.yml"
echo ""

# Create api directory and handler
log_info "Step 11: Creating Lambda API handler"
mkdir -p api
cat > api/handler.js << 'EOL'
'use strict';

module.exports.getData = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';

    return {
      statusCode: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify(
        {
          message: 'Hello from Lambda!',
          user: email,
          timestamp: new Date().toISOString()
        },
        null,
        2
      ),
    };
  } catch (error) {
    return {
      statusCode: 500,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ error: error.message }),
    };
  }
};
EOL
log_success "Created api/handler.js"
echo ""

# Create functions directory and custom resource handler
log_info "Step 12: Creating custom resource Lambda function"
mkdir -p functions
cat > functions/setIdentityPoolRoles.js << EOL
'use strict';

exports.handler = async (event, context) => {
  console.log('REQUEST RECEIVED:', JSON.stringify(event));
  console.log('CONTEXT:', JSON.stringify(context));
  console.log('ENV VARS:', JSON.stringify(process.env));

  // For Delete operations, just succeed
  if (event.RequestType === 'Delete') {
    return;
  }

  try {
    const AWS = require('aws-sdk');
    const cognitoidentity = new AWS.CognitoIdentity({ region: process.env.AWS_REGION || '${REGION}' });

    // Get values from environment variables
    const identityPoolId = process.env.IDENTITY_POOL_ID;
    const authenticatedRoleArn = process.env.AUTHENTICATED_ROLE_ARN;

    if (!identityPoolId) {
      throw new Error('IdentityPoolId is not defined in environment variables');
    }

    if (!authenticatedRoleArn) {
      throw new Error('authenticatedRoleArn is not defined in environment variables');
    }

    console.log(\`Setting roles for identity pool \${identityPoolId}\`);
    console.log(\`Authenticated role: \${authenticatedRoleArn}\`);

    const params = {
      IdentityPoolId: identityPoolId,
      Roles: {
        authenticated: authenticatedRoleArn
      }
    };

    console.log('SetIdentityPoolRoles params:', JSON.stringify(params));

    const result = await cognitoidentity.setIdentityPoolRoles(params).promise();
    console.log('SetIdentityPoolRoles result:', JSON.stringify(result));

    console.log('Successfully set identity pool roles');
  } catch (error) {
    console.error('Error setting identity pool roles:', error);
    throw error;
  }
};
EOL
log_success "Created functions/setIdentityPoolRoles.js"
echo ""

# Create web directory and files
log_info "Step 13: Creating web application files"
mkdir -p web

cat > web/index.html << 'EOL'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Transcription App - Cognito Auth</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <div class="container">
        <h1>Transcription App - Cognito Authentication</h1>
        <div id="login-section">
            <p>Please sign in to access the transcription application.</p>
            <button id="login-button">Sign In</button>
        </div>
        <div id="authenticated-section" style="display: none;">
            <h2>Welcome, <span id="user-email"></span>!</h2>
            <p>You are authenticated and can now access the transcription features.</p>
            <button id="get-data-button">Test Lambda API</button>
            <div id="data-output"></div>
            <button id="logout-button">Sign Out</button>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/amazon-cognito-identity-js/dist/amazon-cognito-identity.min.js"></script>
    <script src="https://sdk.amazonaws.com/js/aws-sdk-2.1000.0.min.js"></script>
    <script src="app.js"></script>
</body>
</html>
EOL

cat > web/callback.html << 'EOL'
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
    <script src="https://sdk.amazonaws.com/js/aws-sdk-2.1000.0.min.js"></script>
    <script>
        // Parse the URL fragment
        const fragment = window.location.hash.substring(1);
        const params = new URLSearchParams(fragment);

        // If we have a code in the query string instead of fragment
        const urlParams = new URLSearchParams(window.location.search);
        const code = urlParams.get('code');

        if (code) {
            // For authorization code flow
            console.log("Authorization code received:", code);
            // In a real app, you would exchange this for tokens
            // For simplicity, we'll just redirect back to the main page
            window.location.href = 'index.html';
        } else {
            // For implicit flow
            // Store the tokens in localStorage
            const idToken = params.get('id_token');
            const accessToken = params.get('access_token');

            if (idToken) {
                localStorage.setItem('id_token', idToken);
            }

            if (accessToken) {
                localStorage.setItem('access_token', accessToken);
            }

            // Redirect back to the main page
            window.location.href = 'index.html';
        }
    </script>
</body>
</html>
EOL

cat > web/styles.css << 'EOL'
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    margin: 0;
    padding: 0;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
}

.container {
    max-width: 600px;
    margin: 0 auto;
    padding: 40px;
    background-color: white;
    box-shadow: 0 10px 40px rgba(0, 0, 0, 0.2);
    border-radius: 12px;
}

h1 {
    color: #333;
    margin-top: 0;
    font-size: 28px;
}

h2 {
    color: #555;
    font-size: 22px;
}

p {
    color: #666;
    line-height: 1.6;
}

button {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    border: none;
    color: white;
    padding: 12px 24px;
    text-align: center;
    text-decoration: none;
    display: inline-block;
    font-size: 16px;
    margin: 10px 5px;
    cursor: pointer;
    border-radius: 6px;
    transition: transform 0.2s, box-shadow 0.2s;
}

button:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 12px rgba(102, 126, 234, 0.4);
}

button:active {
    transform: translateY(0);
}

#logout-button {
    background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
}

#logout-button:hover {
    box-shadow: 0 4px 12px rgba(245, 87, 108, 0.4);
}

#data-output {
    background-color: #f8f9fa;
    border: 1px solid #dee2e6;
    border-radius: 6px;
    padding: 15px;
    margin-top: 20px;
    white-space: pre-wrap;
    font-family: 'Courier New', monospace;
    font-size: 14px;
    min-height: 100px;
    max-height: 300px;
    overflow-y: auto;
    color: #212529;
}

#user-email {
    color: #667eea;
    font-weight: 600;
}
EOL

log_success "Created web files: index.html, callback.html, styles.css"
echo ""

# Update .env file with Cognito configuration
log_info "Step 14: Updating .env with Cognito configuration"
cd "$REPO_ROOT"

# Add Cognito section to .env if it doesn't exist
if ! grep -q "# Cognito/S3/Lambda Configuration" .env; then
    cat >> .env << EOL

# ============================================================================
# Cognito/S3/Lambda Configuration
# ============================================================================
# Cognito authentication stack for web application
COGNITO_APP_NAME=${APP_NAME}
COGNITO_STAGE=${STAGE}
COGNITO_S3_BUCKET=${BUCKET_NAME}
COGNITO_DOMAIN=${COGNITO_DOMAIN}

# Cognito resources (populated after deployment by script 420)
COGNITO_USER_POOL_ID=
COGNITO_USER_POOL_CLIENT_ID=
COGNITO_IDENTITY_POOL_ID=
COGNITO_API_ENDPOINT=
COGNITO_CLOUDFRONT_URL=
EOL
    log_success "Added Cognito configuration to .env"
else
    log_warn "⚠️  Cognito section already exists in .env - skipping"
fi
echo ""

# Update .gitignore
log_info "Step 15: Updating .gitignore"
if [ ! -f .gitignore ]; then
    cat > .gitignore << 'EOL'
# Cognito Stack
cognito-stack/.serverless/
cognito-stack/node_modules/
cognito-stack/web/app.js
cognito-stack/.env

# Logs
logs/
*.log
EOL
    log_success "Created .gitignore"
else
    # Add cognito-stack entries if they don't exist
    if ! grep -q "cognito-stack/.serverless/" .gitignore; then
        cat >> .gitignore << 'EOL'

# Cognito Stack
cognito-stack/.serverless/
cognito-stack/node_modules/
cognito-stack/web/app.js
EOL
        log_success "Updated .gitignore with cognito-stack entries"
    else
        log_info ".gitignore already contains cognito-stack entries"
    fi
fi
echo ""

# ============================================================================
# Success Reporting
# ============================================================================

echo ""
log_info "==================================================================="
log_success "✅ COGNITO/S3/LAMBDA SETUP COMPLETED"
log_info "==================================================================="
echo ""
log_info "Summary:"
log_info "  - Application name: $APP_NAME"
log_info "  - S3 bucket: $BUCKET_NAME"
log_info "  - Cognito domain: $COGNITO_DOMAIN"
log_info "  - Deployment stage: $STAGE"
log_info "  - Project directory: $COGNITO_DIR"
echo ""
log_info "Generated files:"
log_info "  - serverless.yml (CloudFormation template)"
log_info "  - package.json (Node.js dependencies)"
log_info "  - api/handler.js (Lambda API function)"
log_info "  - functions/setIdentityPoolRoles.js (Custom resource)"
log_info "  - web/index.html, web/callback.html, web/styles.css"
echo ""
log_info "Next Steps:"
log_info "  1. Install dependencies: cd $COGNITO_DIR && npm install"
log_info "  2. Validate configuration: ./scripts/415-validate-cognito-setup.sh"
log_info "  3. Deploy the stack: ./scripts/420-deploy-cognito-stack.sh"
echo ""
log_info "⚠️  Important: Configuration saved to .env (do not commit to version control)"
echo ""
