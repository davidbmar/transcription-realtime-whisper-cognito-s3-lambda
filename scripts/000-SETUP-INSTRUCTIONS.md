# Fresh Checkout Setup Instructions

This project is **fully self-contained** - all UI files and Lambda functions are included in this repository.

## Directory Structure

```
transcription-realtime-whisper-cognito-s3-lambda-ver4/  (this repo - everything you need!)
├── cognito-stack/
│   ├── api/                    # Lambda functions (S3, audio, memory)
│   └── serverless.yml          # Full stack definition
├── ui-source/                  # UI source files
│   ├── app.js.template         # File manager frontend
│   ├── audio.html              # WhisperLive audio recorder
│   └── index.html              # Dashboard with cards
└── scripts/                    # Deployment automation
```

## Setup Steps

1. **Clone this repository:**
```bash
git clone https://github.com/davidbmar/transcription-realtime-whisper-cognito-s3-lambda.git transcription-realtime-whisper-cognito-s3-lambda-ver4
cd transcription-realtime-whisper-cognito-s3-lambda-ver4
```

2. **Configure environment:**
```bash
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

## What's Included

All necessary files are in this single repository:
- **Lambda Functions:** cognito-stack/api/ (S3, audio, memory operations)
- **UI Files:** ui-source/ (dashboard, file manager, audio recorder)
- **Deployment Scripts:** scripts/ (fully automated deployment)
- **Infrastructure:** cognito-stack/serverless.yml (Cognito, S3, API Gateway, CloudFront)
