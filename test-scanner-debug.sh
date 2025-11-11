#!/bin/bash
set -x

SESSION_PATH="users/512b3590-30b1-707d-ed46-bf68df7b52d5/audio/sessions/2025-11-02-session_2025-11-02T04_18_57_092Z"

echo "Testing audio chunk extraction..."
AUDIO_CHUNKS=$(aws s3 ls "s3://clouddrive-app-bucket/$SESSION_PATH/" 2>/dev/null | \
    grep -E 'chunk-[0-9]+\.webm$' | \
    awk '{print $4}' | \
    sed 's/chunk-//' | \
    sed 's/\.webm$//' | \
    sort -n)

echo "Exit code: $?"
echo "Audio chunks: $AUDIO_CHUNKS"
echo "Count: $(echo "$AUDIO_CHUNKS" | wc -l)"

echo ""
echo "Testing transcription chunk extraction..."
TRANSCRIPTION_CHUNKS=$(aws s3 ls "s3://clouddrive-app-bucket/$SESSION_PATH/" 2>/dev/null | \
    grep -E 'transcription-chunk-[0-9]+\.json$' | \
    awk '{print $4}' | \
    sed 's/transcription-chunk-//' | \
    sed 's/\.json$//' | \
    sort -n)

echo "Exit code: $?"
echo "Transcription chunks: $TRANSCRIPTION_CHUNKS"
echo "Count: $(echo "$TRANSCRIPTION_CHUNKS" | wc -l)"
