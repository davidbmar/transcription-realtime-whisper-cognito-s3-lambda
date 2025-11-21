#!/usr/bin/env node

/**
 * Script 517: Server-Side Transcript Preprocessing
 *
 * Runs after batch transcription to generate a pre-processed transcript file.
 * This eliminates client-side processing and dramatically speeds up editor loading.
 *
 * Usage:
 *   node scripts/517-preprocess-transcript.js <session-folder>
 *
 * Example:
 *   node scripts/517-preprocess-transcript.js audio-sessions/user-id/2025-11-18T15_07_04_017Z
 *
 * What it does:
 *   1. Download all transcription-chunk-*.json files from S3
 *   2. Run boundary deduplication preprocessor
 *   3. Generate transcription-processed.json
 *   4. Upload to S3 in same folder
 *
 * Performance impact:
 *   - Before: Editor loads 16-379 chunks sequentially (~5-120 seconds)
 *   - After: Editor loads 1 pre-processed file (~500ms)
 */

const fs = require('fs');
const path = require('path');
const { S3Client, ListObjectsV2Command, GetObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');
const { fromEnv } = require('@aws-sdk/credential-providers');

// Load environment
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

// Import preprocessor
const TranscriptPreprocessorBoundary = require('../ui-source/transcript-preprocessor-boundary.js');

// AWS SDK v3 setup
const s3Client = new S3Client({
  region: process.env.AWS_REGION || 'us-east-2',
  credentials: fromEnv()
});

const BUCKET = process.env.COGNITO_S3_BUCKET;

async function streamToString(stream) {
  const chunks = [];
  return new Promise((resolve, reject) => {
    stream.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
    stream.on('error', reject);
    stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

async function downloadChunks(sessionFolder) {
  console.log(`Listing transcription chunks in s3://${BUCKET}/${sessionFolder}/`);

  const listCommand = new ListObjectsV2Command({
    Bucket: BUCKET,
    Prefix: `${sessionFolder}/`
  });

  const response = await s3Client.send(listCommand);

  const chunkFiles = response.Contents
    .filter(obj => obj.Key.includes('transcription-chunk-') && obj.Key.endsWith('.json'))
    .sort((a, b) => {
      const aNum = parseInt(a.Key.match(/chunk-(\d+)\.json/)?.[1] || '0');
      const bNum = parseInt(b.Key.match(/chunk-(\d+)\.json/)?.[1] || '0');
      return aNum - bNum;
    });

  console.log(`Found ${chunkFiles.length} transcription chunks`);

  const chunks = [];
  for (const file of chunkFiles) {
    const chunkNum = parseInt(file.Key.match(/chunk-(\d+)\.json/)?.[1] || '0');
    console.log(`  Downloading chunk ${chunkNum}...`);

    const getCommand = new GetObjectCommand({
      Bucket: BUCKET,
      Key: file.Key
    });

    const data = await s3Client.send(getCommand);
    const bodyContents = await streamToString(data.Body);
    const chunkData = JSON.parse(bodyContents);

    chunks.push({
      chunkIndex: chunkNum,
      chunkId: `chunk-${String(chunkNum).padStart(3, '0')}`,
      ...chunkData
    });
  }

  return chunks;
}

async function preprocessTranscript(chunks) {
  console.log('Running boundary deduplication preprocessor...');

  const preprocessor = new TranscriptPreprocessorBoundary({
    maxBoundaryWords: 10
  });

  const result = preprocessor.process(chunks);

  console.log(`Preprocessed ${chunks.length} chunks into ${result.paragraphs.length} paragraphs`);
  console.log(`Stats:`, result.stats);

  return result;
}

async function uploadProcessedFile(sessionFolder, processedData) {
  const key = `${sessionFolder}/transcription-processed.json`;
  console.log(`Uploading pre-processed transcript to s3://${BUCKET}/${key}`);

  const putCommand = new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    Body: JSON.stringify(processedData, null, 2),
    ContentType: 'application/json',
    Metadata: {
      'generated-by': 'batch-transcription-preprocessor',
      'generated-at': new Date().toISOString(),
      'paragraph-count': String(processedData.paragraphs.length),
      'total-words': String(processedData.stats.totalWords)
    }
  });

  await s3Client.send(putCommand);
  console.log('✅ Pre-processed transcript uploaded successfully');
}

async function main() {
  const sessionFolder = process.argv[2];

  if (!sessionFolder) {
    console.error('Usage: node 517-preprocess-transcript.js <session-folder>');
    console.error('Example: node 517-preprocess-transcript.js audio-sessions/user-id/2025-11-18T15_07_04_017Z');
    process.exit(1);
  }

  if (!BUCKET) {
    console.error('ERROR: COGNITO_S3_BUCKET not set in .env');
    process.exit(1);
  }

  console.log('==========================================================');
  console.log('517: Server-Side Transcript Preprocessing');
  console.log('==========================================================');
  console.log('Session folder:', sessionFolder);
  console.log('S3 bucket:', BUCKET);
  console.log('');

  try {
    // Step 1: Download all chunks
    const chunks = await downloadChunks(sessionFolder);

    if (chunks.length === 0) {
      console.error('ERROR: No transcription chunks found');
      process.exit(1);
    }

    // Step 2: Preprocess
    const processedData = await preprocessTranscript(chunks);

    // Step 3: Upload
    await uploadProcessedFile(sessionFolder, processedData);

    console.log('');
    console.log('✅ Preprocessing complete!');
    console.log('   Editor will now load in ~500ms instead of ~5 seconds');
    console.log('');

  } catch (error) {
    console.error('ERROR:', error.message);
    console.error(error.stack);
    process.exit(1);
  }
}

main();
