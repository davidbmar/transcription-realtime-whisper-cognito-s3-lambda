# Fresh Checkout Setup Instructions

This project depends on the `audio-ui-cf-s3-lambda-cognito` repository for UI files.

## Directory Structure

```
event-b/
├── transcription-realtime-whisper-cognito-s3-lambda-ver4/  (this repo)
└── audio-ui-cf-s3-lambda-cognito/                          (UI repo)
```

## Setup Steps

1. **Clone both repositories:**
```bash
cd /home/ubuntu/event-b/
git clone https://github.com/davidbmar/transcription-realtime-whisper-cognito-s3-lambda.git transcription-realtime-whisper-cognito-s3-lambda-ver4
git clone https://github.com/davidbmar/audio-ui-cf-s3-lambda-cognito.git
```

2. **Configure environment:**
```bash
cd transcription-realtime-whisper-cognito-s3-lambda-ver4
cp .env.template .env
# Edit .env with your values
```

3. **Run deployment scripts in order:**
```bash
# Deploy Cognito authentication stack
./scripts/410-create-cognito-stack.sh
./scripts/420-deploy-cognito.sh

# Deploy recorder UI with dark glass theme
./scripts/425-deploy-recorder-ui.sh

# (Optional) Deploy additional components
./scripts/430-test-auth.sh
```

## Required .env Variables

Key variables that must be set:
- `COGNITO_APP_NAME` - Your app name
- `COGNITO_STAGE` - dev/prod
- `AWS_REGION` - AWS region
- `WHISPERLIVE_WS_URL` - WebSocket URL for real-time transcription (optional)
- `EDGE_BOX_DNS` - Your edge box domain (optional)

## Dependencies

- AWS CLI configured with credentials
- Node.js and npm (for Serverless Framework)
- Serverless Framework
- Both repos checked out in parallel directories
