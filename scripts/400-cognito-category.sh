#!/bin/bash
set -euo pipefail

cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║             🔐  COGNITO/S3/LAMBDA AUTHENTICATION (4xx)                    ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

This category contains scripts for deploying serverless authentication
infrastructure using AWS Cognito, S3 website hosting, CloudFront CDN,
and Lambda API functions.

═══════════════════════════════════════════════════════════════════════════

SCRIPTS IN THIS CATEGORY:

  410-questions-setup-cognito-s3-lambda.sh  ⭐ START HERE
    • Interactive setup with guided prompts
    • Generates serverless.yml CloudFormation template
    • Creates Lambda function handlers
    • Creates web application files (HTML, CSS, JS templates)
    • Updates .env with Cognito configuration
    • Takes ~2 minutes

  415-validate-cognito-setup.sh
    • Validates that script 410 completed successfully
    • Checks all required files are in place
    • Validates serverless.yml structure
    • Checks AWS credentials and permissions
    • Verifies resource naming availability
    • Takes ~30 seconds

  420-deploy-cognito-stack.sh
    • Installs Node.js dependencies (serverless framework)
    • Deploys complete CloudFormation stack
    • Creates Cognito User Pool + Identity Pool
    • Creates S3 bucket + CloudFront distribution
    • Deploys Lambda functions + API Gateway
    • Retrieves all resource IDs
    • Updates .env with deployment outputs
    • Takes ~10-15 minutes (CloudFormation is slow)

  430-create-cognito-user.sh
    • Creates test user in Cognito User Pool
    • Prompts for email and password
    • Validates password complexity requirements
    • Sets permanent password (not temporary)
    • Takes ~30 seconds

  499-cleanup-cognito-stack.sh
    • Removes ALL Cognito resources (IRREVERSIBLE!)
    • Empties and deletes S3 buckets
    • Deletes Cognito User Pool and all users
    • Deletes CloudFormation stack
    • Cleans up .env variables
    • Requires double confirmation (yes + app name)
    • Takes ~10-15 minutes

═══════════════════════════════════════════════════════════════════════════

TYPICAL WORKFLOW:

  First Time Setup:
    1. ./scripts/410-questions-setup-cognito-s3-lambda.sh
    2. ./scripts/415-validate-cognito-setup.sh
    3. cd cognito-stack && npm install
    4. cd .. && ./scripts/420-deploy-cognito-stack.sh
    5. ./scripts/430-create-cognito-user.sh
    6. Test: Open CloudFront URL in browser and sign in

  To Create Additional Users:
    ./scripts/430-create-cognito-user.sh

  To Completely Remove Everything:
    ./scripts/499-cleanup-cognito-stack.sh

═══════════════════════════════════════════════════════════════════════════

WHAT GETS DEPLOYED:

  AWS Resources:
    • Cognito User Pool (user management)
    • Cognito Identity Pool (AWS credential vending)
    • Cognito User Pool Client (app integration)
    • Cognito Domain (authentication UI)
    • S3 Bucket (website hosting)
    • CloudFront Distribution (global CDN)
    • Lambda Functions (API endpoints)
    • API Gateway (HTTP API with Cognito authorizer)
    • IAM Roles (authenticated user permissions)

  Project Structure:
    cognito-stack/
      ├── serverless.yml          (CloudFormation template)
      ├── package.json            (Node.js dependencies)
      ├── api/
      │   └── handler.js          (Lambda API function)
      ├── functions/
      │   └── setIdentityPoolRoles.js  (Custom resource)
      └── web/
          ├── index.html          (Main page)
          ├── callback.html       (OAuth callback)
          ├── styles.css          (Styles)
          └── app.js              (Generated with deployment values)

═══════════════════════════════════════════════════════════════════════════

MONTHLY COSTS (APPROXIMATE):

  Free Tier (first 12 months):
    • Cognito: 50,000 MAUs free
    • S3: 5GB storage free
    • CloudFront: 1TB data transfer free
    • Lambda: 1M requests free
    • API Gateway: 1M requests free

  Beyond Free Tier:
    • Cognito: $0.0055 per MAU (after 50k)
    • S3: $0.023 per GB
    • CloudFront: $0.085 per GB (first 10TB)
    • Lambda: $0.20 per 1M requests
    • API Gateway: $1.00 per 1M requests

  Typical low-traffic site: < $5/month

═══════════════════════════════════════════════════════════════════════════

INTEGRATION WITH EXISTING RECORDER:

  Current Status:
    • The existing transcription recorder (site/index.html) at the edge
      proxy (3.16.164.228:8444/demo.html) is UNCHANGED
    • The 4xx scripts create SEPARATE authentication infrastructure
    • Both can run independently

  Future Integration Options:
    1. Deploy recorder to Cognito-protected CloudFront site
    2. Add authentication checks to recorder UI
    3. Use Cognito credentials when connecting to WhisperLive

═══════════════════════════════════════════════════════════════════════════

After deployment completes, access your application at:
  https://${COGNITO_CLOUDFRONT_URL:-[CloudFront-URL-from-deployment]}

Authentication domain:
  https://${COGNITO_DOMAIN:-[domain]}.auth.${AWS_REGION:-us-east-2}.amazoncognito.com

EOF
