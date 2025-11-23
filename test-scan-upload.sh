#!/bin/bash
source .env

SESSION_PATH="users/512b3590-30b1-707d-ed46-bf68df7b52d5/audio/sessions/20251122-190205-upload-5b4c464c39d2"

echo "Testing session: $SESSION_PATH"
echo ""

echo "1. Checking for audio chunks..."
AUDIO_CHUNKS=$(aws s3 ls "s3://$COGNITO_S3_BUCKET/$SESSION_PATH/" 2>/dev/null | \
    grep -E 'chunk-[0-9]+\.(webm|aac|m4a|mp3|wav|ogg|flac)$')
echo "$AUDIO_CHUNKS"
echo ""

echo "2. Checking for transcription chunks..."
TRANSCRIPTION_CHUNKS=$(aws s3 ls "s3://$COGNITO_S3_BUCKET/$SESSION_PATH/" 2>/dev/null | \
    grep -E 'transcription-chunk-[0-9]+\.json$')
echo "$TRANSCRIPTION_CHUNKS"
echo ""

echo "3. Checking for completion marker..."
if aws s3 ls "s3://$COGNITO_S3_BUCKET/$SESSION_PATH/.transcription-complete" >/dev/null 2>&1; then
    echo "HAS COMPLETION MARKER"
else
    echo "NO COMPLETION MARKER"
fi
