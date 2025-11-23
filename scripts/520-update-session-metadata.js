#!/usr/bin/env node

/**
 * Script 520: Update Session Metadata
 *
 * Updates session metadata.json with transcription completion status.
 * Called by script 518 after preprocessing and formatting complete.
 *
 * Usage:
 *   node scripts/520-update-session-metadata.js <session-folder> <status>
 *
 * Example:
 *   node scripts/520-update-session-metadata.js users/user-id/audio/sessions/session-id complete
 *
 * What it does:
 *   1. Download metadata.json from S3
 *   2. Update transcription.status field
 *   3. Add completedAt timestamp if status is 'complete'
 *   4. Upload updated metadata back to S3
 *
 * Valid statuses:
 *   - pending: Transcription not started yet
 *   - processing: Batch transcription in progress
 *   - complete: Transcription finished successfully
 *   - error: Transcription failed
 */

const fs = require('fs');
const path = require('path');
const { S3Client, GetObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');

// Load environment
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

// AWS SDK v3 setup
const s3Client = new S3Client({
  region: process.env.AWS_REGION || 'us-east-2'
});

const BUCKET = process.env.COGNITO_S3_BUCKET;

// Valid status values
const VALID_STATUSES = ['pending', 'processing', 'complete', 'error'];

async function streamToString(stream) {
  const chunks = [];
  return new Promise((resolve, reject) => {
    stream.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
    stream.on('error', reject);
    stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

async function downloadMetadata(sessionFolder) {
  const key = `${sessionFolder}/metadata.json`;
  console.log(`Downloading metadata from s3://${BUCKET}/${key}`);

  const getCommand = new GetObjectCommand({
    Bucket: BUCKET,
    Key: key
  });

  try {
    const data = await s3Client.send(getCommand);
    const bodyContents = await streamToString(data.Body);
    return JSON.parse(bodyContents);
  } catch (error) {
    if (error.name === 'NoSuchKey') {
      throw new Error(`Metadata not found at s3://${BUCKET}/${key}`);
    }
    throw error;
  }
}

async function uploadMetadata(sessionFolder, metadata) {
  const key = `${sessionFolder}/metadata.json`;
  console.log(`Uploading updated metadata to s3://${BUCKET}/${key}`);

  const putCommand = new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    Body: JSON.stringify(metadata, null, 2),
    ContentType: 'application/json'
  });

  await s3Client.send(putCommand);
  console.log('✓ Metadata updated successfully');
}

function updateMetadataStatus(metadata, status) {
  console.log(`Updating transcription status: ${metadata.transcription?.status || 'none'} → ${status}`);

  // Initialize transcription object if it doesn't exist
  if (!metadata.transcription) {
    metadata.transcription = {};
  }

  // Update status
  metadata.transcription.status = status;

  // Add timestamp for completion
  if (status === 'complete') {
    metadata.transcription.completedAt = new Date().toISOString();
    metadata.transcriptionStatus = 'completed'; // For backward compatibility
  } else if (status === 'processing') {
    metadata.transcriptionStatus = 'processing';
  } else if (status === 'pending') {
    metadata.transcriptionStatus = 'pending';
  } else if (status === 'error') {
    metadata.transcriptionStatus = 'error';
  }

  // Update general metadata timestamp
  metadata.updatedAt = new Date().toISOString();

  return metadata;
}

async function main() {
  const sessionFolder = process.argv[2];
  const status = process.argv[3];

  if (!sessionFolder || !status) {
    console.error('Usage: node 520-update-session-metadata.js <session-folder> <status>');
    console.error('Example: node 520-update-session-metadata.js users/123/audio/sessions/session-id complete');
    console.error('');
    console.error('Valid statuses: pending, processing, complete, error');
    process.exit(1);
  }

  if (!VALID_STATUSES.includes(status)) {
    console.error(`Error: Invalid status '${status}'`);
    console.error(`Valid statuses: ${VALID_STATUSES.join(', ')}`);
    process.exit(1);
  }

  if (!BUCKET) {
    console.error('Error: COGNITO_S3_BUCKET environment variable not set');
    process.exit(1);
  }

  console.log('='.repeat(60));
  console.log('Script 520: Update Session Metadata');
  console.log('='.repeat(60));
  console.log(`Session folder: ${sessionFolder}`);
  console.log(`New status: ${status}`);
  console.log(`S3 bucket: ${BUCKET}`);
  console.log('');

  try {
    // Download current metadata
    const metadata = await downloadMetadata(sessionFolder);
    console.log(`Current status: ${metadata.transcription?.status || 'none'}`);
    console.log('');

    // Update metadata
    const updatedMetadata = updateMetadataStatus(metadata, status);
    console.log('');

    // Upload updated metadata
    await uploadMetadata(sessionFolder, updatedMetadata);
    console.log('');

    console.log('='.repeat(60));
    console.log('✓ Metadata update complete');
    console.log('='.repeat(60));
    console.log('');

  } catch (error) {
    console.error('');
    console.error('Error:', error.message);
    console.error(error.stack);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  main();
}

// Export for testing
module.exports = {
  updateMetadataStatus,
  downloadMetadata,
  uploadMetadata
};
