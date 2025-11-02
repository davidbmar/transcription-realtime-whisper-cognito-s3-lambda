'use strict';

const AWS = require('aws-sdk');
const s3 = new AWS.S3();

// Secure CORS helper - only allow specific origins
const getAllowedOrigin = (requestOrigin) => {
  const allowedOrigins = [
    process.env.CLOUDFRONT_URL
  ].filter(Boolean); // Remove undefined values

  return allowedOrigins.includes(requestOrigin) ? requestOrigin : allowedOrigins[0];
};

// Standard security headers
const getSecurityHeaders = (requestOrigin) => ({
  'Access-Control-Allow-Origin': getAllowedOrigin(requestOrigin),
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type, Content-Length',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'X-XSS-Protection': '1; mode=block',
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'Referrer-Policy': 'strict-origin-when-cross-origin'
});

module.exports.listObjects = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown'; // Cognito user ID
    
    console.log(`User ${email} (${userId}) requesting S3 objects`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Parse query parameters
    const queryParams = event.queryStringParameters || {};
    const onlyNames = queryParams.onlyNames === 'true';
    const userScope = queryParams.userScope !== 'false'; // Default to user-scoped


    // Determine the prefix based on user scope
    let prefix;
    if (userScope) {
      // User-specific files only
      const userPrefix = `users/${userId}/`;
      prefix = queryParams.prefix ? `${userPrefix}${queryParams.prefix}` : userPrefix;
    } else {
      // Global files - allow memory files and user files for authenticated users
      prefix = queryParams.prefix || '';
      
      // Security check: only allow memory paths and user paths when userScope=false
      if (prefix && !prefix.startsWith('claude-memory/') && !prefix.startsWith(`users/${userId}/`)) {
        throw new Error('Access denied: Invalid prefix for global scope');
      }
    }
    
    console.log(`Listing S3 objects in bucket: ${bucketName}, prefix: ${prefix}, onlyNames: ${onlyNames}`);

    // List objects in S3 bucket
    const s3Params = {
      Bucket: bucketName,
      Prefix: prefix,
      MaxKeys: 100 // Limit results for now
    };

    const s3Response = await s3.listObjectsV2(s3Params).promise();
    
    console.log(`Found ${s3Response.Contents?.length || 0} objects`);

    // Process the results based on the onlyNames flag
    let files;
    if (onlyNames) {
      // Return just filenames, removing the user prefix for cleaner display
      files = (s3Response.Contents || []).map(obj => {
        if (userScope && obj.Key.startsWith(`users/${userId}/`)) {
          return obj.Key.replace(`users/${userId}/`, '');
        }
        return obj.Key;
      });
    } else {
      // Return full metadata with clean display names
      files = (s3Response.Contents || []).map(obj => {
        let displayKey = obj.Key;
        if (userScope && obj.Key.startsWith(`users/${userId}/`)) {
          displayKey = obj.Key.replace(`users/${userId}/`, '');
        }
        
        return {
          key: obj.Key, // Original S3 key
          displayKey: displayKey, // Clean display name
          size: obj.Size,
          lastModified: obj.LastModified,
          etag: obj.ETag,
          storageClass: obj.StorageClass || 'STANDARD'
        };
      });
    }

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'S3 listing successful',
        user: email,
        userId: userId,
        bucket: bucketName,
        prefix: prefix,
        userScope: userScope,
        count: files.length,
        onlyNames: onlyNames,
        files: files,
        timestamp: new Date().toISOString()
      }, null, 2),
    };
  } catch (error) {
    console.error('Error listing S3 objects:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// New function for generating pre-signed download URLs
module.exports.getDownloadUrl = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) requesting download URL`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Get the file key from path parameters
    const fileKey = event.pathParameters?.key;
    if (!fileKey) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'File key is required' }),
      };
    }

    // Decode the file key (in case it was URL encoded)
    const decodedKey = decodeURIComponent(fileKey);

   
    // REPLACE with this enhanced security check:
    // Security check: Allow access to user files AND their memory files
    const userPrefix = `users/${userId}/`;
    const userMemoryPrefix = `claude-memory/${userId}/`;
    const publicMemoryPrefix = `claude-memory/public/`;
    
    if (!decodedKey.startsWith(userPrefix) && 
        !decodedKey.startsWith(userMemoryPrefix) && 
        !decodedKey.startsWith(publicMemoryPrefix)) {
      return {
        statusCode: 403,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ 
          error: 'Access denied: You can only access your own files and memory data' 
        }),
      };
    }

    // Check if file exists
    try {
      await s3.headObject({ Bucket: bucketName, Key: decodedKey }).promise();
    } catch (error) {
      if (error.code === 'NotFound') {
        return {
          statusCode: 404,
          headers: {
            ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
            'Access-Control-Allow-Credentials': true,
          },
          body: JSON.stringify({ error: 'File not found' }),
        };
      }
      throw error;
    }

    // Generate pre-signed URL for download (valid for 15 minutes)
    const filename = decodedKey.split('/').pop();
    // Sanitize filename for content-disposition header (ASCII only)
    const sanitizedFilename = filename.replace(/[^\x20-\x7E]/g, '_');
    
    const downloadUrl = s3.getSignedUrl('getObject', {
      Bucket: bucketName,
      Key: decodedKey,
      Expires: 60 * 15, // 15 minutes
      ResponseContentDisposition: `attachment; filename="${sanitizedFilename}"` // Force download
    });

    console.log(`Generated download URL for ${decodedKey}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Download URL generated successfully',
        user: email,
        userId: userId,
        fileKey: decodedKey,
        downloadUrl: downloadUrl,
        expiresIn: 900, // 15 minutes in seconds
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error generating download URL:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// New function for generating pre-signed upload URLs
module.exports.getUploadUrl = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) requesting upload URL`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const fileName = body.fileName;
    const contentType = body.contentType || 'application/octet-stream';
    const fileSize = body.fileSize;

    // Validate input
    if (!fileName) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'fileName is required' }),
      };
    }

    // Validate file size (max 100MB)
    const maxSize = 100 * 1024 * 1024; // 100MB
    if (fileSize && fileSize > maxSize) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ 
          error: `File size exceeds maximum allowed size of ${maxSize / 1024 / 1024}MB` 
        }),
      };
    }

    // Allow folder paths but prevent path traversal (../)
    const sanitizedFileName = fileName.replace(/\.\.\//g, '').replace(/\.\.\\/g, '');
    
    // Create the S3 key for the user's file
    const fileKey = `users/${userId}/${sanitizedFileName}`;
    
    console.log(`Generating upload URL for ${fileKey}, content-type: ${contentType}`);

    // Generate pre-signed URL for upload (valid for 5 minutes)
    const uploadUrl = s3.getSignedUrl('putObject', {
      Bucket: bucketName,
      Key: fileKey,
      Expires: 60 * 5, // 5 minutes
      ContentType: contentType
    });

    console.log(`Generated upload URL for ${fileKey}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'Upload URL generated successfully',
        user: email,
        userId: userId,
        fileName: sanitizedFileName,
        fileKey: fileKey,
        uploadUrl: uploadUrl,
        contentType: contentType,
        expiresIn: 300, // 5 minutes in seconds
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error generating upload URL:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// New function for deleting files
module.exports.deleteObject = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) requesting file deletion`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Get the file key from path parameters or body
    let fileKey = event.pathParameters?.key;
    if (!fileKey && event.body) {
      const body = JSON.parse(event.body);
      fileKey = body.fileKey;
    }
    
    if (!fileKey) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'File key is required' }),
      };
    }

    // Decode the file key (in case it was URL encoded)
    const decodedKey = decodeURIComponent(fileKey);
    
    // Security check: only allow deletion of user's own files
    const userPrefix = `users/${userId}/`;
    if (!decodedKey.startsWith(userPrefix)) {
      return {
        statusCode: 403,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ 
          error: 'Access denied: You can only delete your own files' 
        }),
      };
    }

    console.log(`Deleting S3 object: ${decodedKey}`);

    // Delete the object from S3
    await s3.deleteObject({
      Bucket: bucketName,
      Key: decodedKey
    }).promise();

    console.log(`Successfully deleted: ${decodedKey}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'File deleted successfully',
        user: email,
        userId: userId,
        deletedFile: decodedKey,
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error deleting file:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// New function for renaming files
module.exports.renameObject = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) requesting file rename`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const oldKey = body.oldKey;
    const newName = body.newName;
    
    if (!oldKey || !newName) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'oldKey and newName are required' }),
      };
    }

    // Decode the old key (in case it was URL encoded)
    const decodedOldKey = decodeURIComponent(oldKey);
    
    // Security check: only allow renaming of user's own files
    const userPrefix = `users/${userId}/`;
    if (!decodedOldKey.startsWith(userPrefix)) {
      return {
        statusCode: 403,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ 
          error: 'Access denied: You can only rename your own files' 
        }),
      };
    }

    // Sanitize new name - allow alphanumeric, spaces, hyphens, underscores, dots, and forward slashes
    const sanitizedNewName = newName.replace(/[^a-zA-Z0-9\-_\s\.\/]/g, '').trim();
    if (!sanitizedNewName) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ 
          error: 'Invalid file name. Use only letters, numbers, spaces, hyphens, underscores, dots, and forward slashes.' 
        }),
      };
    }

    // Build the new key maintaining the folder structure
    let newKey;
    const oldKeyParts = decodedOldKey.split('/');
    const isFolder = decodedOldKey.endsWith('/');
    
    if (isFolder) {
      // For folders, replace the folder name in the path
      oldKeyParts[oldKeyParts.length - 2] = sanitizedNewName; // -2 because last element is empty for folders
      newKey = oldKeyParts.join('/');
    } else {
      // For files, replace just the filename
      oldKeyParts[oldKeyParts.length - 1] = sanitizedNewName;
      newKey = oldKeyParts.join('/');
    }

    // Make sure the new key still starts with the user prefix
    if (!newKey.startsWith(userPrefix)) {
      return {
        statusCode: 403,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ 
          error: 'Invalid rename operation' 
        }),
      };
    }

    console.log(`Renaming from ${decodedOldKey} to ${newKey}`);

    // Check if source exists
    try {
      await s3.headObject({ Bucket: bucketName, Key: decodedOldKey }).promise();
    } catch (error) {
      if (error.code === 'NotFound') {
        return {
          statusCode: 404,
          headers: {
            ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
            'Access-Control-Allow-Credentials': true,
          },
          body: JSON.stringify({ error: 'Source file not found' }),
        };
      }
      throw error;
    }

    // Check if destination already exists
    try {
      await s3.headObject({ Bucket: bucketName, Key: newKey }).promise();
      return {
        statusCode: 409,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'A file with that name already exists' }),
      };
    } catch (error) {
      // If error is NotFound, that's good - we can proceed
      if (error.code !== 'NotFound') {
        throw error;
      }
    }

    if (isFolder) {
      // For folders, we need to rename all objects with that prefix
      const listParams = {
        Bucket: bucketName,
        Prefix: decodedOldKey
      };
      
      const objects = await s3.listObjectsV2(listParams).promise();
      
      if (objects.Contents && objects.Contents.length > 0) {
        // Copy all objects to new location
        const copyPromises = objects.Contents.map(async (obj) => {
          const oldObjKey = obj.Key;
          const newObjKey = oldObjKey.replace(decodedOldKey, newKey);
          
          await s3.copyObject({
            Bucket: bucketName,
            CopySource: encodeURIComponent(`${bucketName}/${oldObjKey}`),
            Key: newObjKey
          }).promise();
        });
        
        await Promise.all(copyPromises);
        
        // Delete all old objects
        const deleteObjects = objects.Contents.map(obj => ({ Key: obj.Key }));
        await s3.deleteObjects({
          Bucket: bucketName,
          Delete: { Objects: deleteObjects }
        }).promise();
      }
    } else {
      // For single file, copy to new location
      await s3.copyObject({
        Bucket: bucketName,
        CopySource: encodeURIComponent(`${bucketName}/${decodedOldKey}`),
        Key: newKey
      }).promise();

      // Delete the old file
      await s3.deleteObject({
        Bucket: bucketName,
        Key: decodedOldKey
      }).promise();
    }

    console.log(`Successfully renamed from ${decodedOldKey} to ${newKey}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'File renamed successfully',
        user: email,
        userId: userId,
        oldKey: decodedOldKey,
        newKey: newKey,
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error renaming file:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};

// New function for moving files/folders
module.exports.moveObject = async (event) => {
  try {
    // Get user claims from the authorizer
    const claims = event.requestContext?.authorizer?.claims || {};
    const email = claims.email || 'Anonymous';
    const userId = claims.sub || 'unknown';
    
    console.log(`User ${email} (${userId}) requesting file move`);

    // Get bucket name from environment variable
    const bucketName = process.env.S3_BUCKET_NAME;
    if (!bucketName) {
      throw new Error('S3_BUCKET_NAME environment variable not set');
    }

    // Parse request body
    const body = JSON.parse(event.body || '{}');
    const sourceKey = body.sourceKey;
    const destinationPath = body.destinationPath || '';
    
    if (!sourceKey) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'sourceKey is required' }),
      };
    }

    // Decode the source key (in case it was URL encoded)
    const decodedSourceKey = decodeURIComponent(sourceKey);
    
    // Security check: only allow moving user's own files
    const userPrefix = `users/${userId}/`;
    if (!decodedSourceKey.startsWith(userPrefix)) {
      return {
        statusCode: 403,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ 
          error: 'Access denied: You can only move your own files' 
        }),
      };
    }

    // Sanitize destination path
    const sanitizedDestination = destinationPath.replace(/[^a-zA-Z0-9\-_\s\.\/]/g, '').trim();
    
    // Build the new key
    const fileName = decodedSourceKey.split('/').pop();
    const isFolder = decodedSourceKey.endsWith('/');
    
    let newKey;
    if (sanitizedDestination) {
      // Ensure destination path ends with / for folders and doesn't for files
      const normalizedDest = sanitizedDestination.replace(/\/+$/, '') + '/';
      newKey = `${userPrefix}${normalizedDest}${fileName}`;
    } else {
      // Moving to root
      newKey = `${userPrefix}${fileName}`;
    }

    // Prevent moving to same location
    if (decodedSourceKey === newKey) {
      return {
        statusCode: 400,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'Source and destination are the same' }),
      };
    }

    console.log(`Moving from ${decodedSourceKey} to ${newKey}`);

    // Check if source exists
    try {
      await s3.headObject({ Bucket: bucketName, Key: decodedSourceKey }).promise();
    } catch (error) {
      if (error.code === 'NotFound') {
        return {
          statusCode: 404,
          headers: {
            ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
            'Access-Control-Allow-Credentials': true,
          },
          body: JSON.stringify({ error: 'Source file not found' }),
        };
      }
      throw error;
    }

    // Check if destination already exists
    try {
      await s3.headObject({ Bucket: bucketName, Key: newKey }).promise();
      return {
        statusCode: 409,
        headers: {
          ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
          'Access-Control-Allow-Credentials': true,
        },
        body: JSON.stringify({ error: 'A file with that name already exists at the destination' }),
      };
    } catch (error) {
      // If error is NotFound, that's good - we can proceed
      if (error.code !== 'NotFound') {
        throw error;
      }
    }

    if (isFolder) {
      // For folders, we need to move all objects with that prefix
      const listParams = {
        Bucket: bucketName,
        Prefix: decodedSourceKey
      };
      
      const objects = await s3.listObjectsV2(listParams).promise();
      
      if (objects.Contents && objects.Contents.length > 0) {
        // Copy all objects to new location
        const copyPromises = objects.Contents.map(async (obj) => {
          const oldObjKey = obj.Key;
          const newObjKey = oldObjKey.replace(decodedSourceKey, newKey);
          
          await s3.copyObject({
            Bucket: bucketName,
            CopySource: encodeURIComponent(`${bucketName}/${oldObjKey}`),
            Key: newObjKey
          }).promise();
        });
        
        await Promise.all(copyPromises);
        
        // Delete all old objects
        const deleteObjects = objects.Contents.map(obj => ({ Key: obj.Key }));
        await s3.deleteObjects({
          Bucket: bucketName,
          Delete: { Objects: deleteObjects }
        }).promise();
      }
    } else {
      // For single file, copy to new location
      await s3.copyObject({
        Bucket: bucketName,
        CopySource: encodeURIComponent(`${bucketName}/${decodedSourceKey}`),
        Key: newKey
      }).promise();

      // Delete the old file
      await s3.deleteObject({
        Bucket: bucketName,
        Key: decodedSourceKey
      }).promise();
    }

    console.log(`Successfully moved from ${decodedSourceKey} to ${newKey}`);

    return {
      statusCode: 200,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({
        message: 'File moved successfully',
        user: email,
        userId: userId,
        sourceKey: decodedSourceKey,
        destinationKey: newKey,
        timestamp: new Date().toISOString()
      }),
    };
  } catch (error) {
    console.error('Error moving file:', error);
    return {
      statusCode: 500,
      headers: {
        ...getSecurityHeaders(event.headers?.origin || event.headers?.Origin),
        'Access-Control-Allow-Credentials': true,
      },
      body: JSON.stringify({ 
        error: error.message,
        timestamp: new Date().toISOString()
      }),
    };
  }
};
