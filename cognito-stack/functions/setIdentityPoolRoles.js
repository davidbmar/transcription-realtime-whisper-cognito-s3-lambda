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
    const cognitoidentity = new AWS.CognitoIdentity({ region: process.env.AWS_REGION || 'us-east-2' });

    // Get values from environment variables
    const identityPoolId = process.env.IDENTITY_POOL_ID;
    const authenticatedRoleArn = process.env.AUTHENTICATED_ROLE_ARN;

    if (!identityPoolId) {
      throw new Error('IdentityPoolId is not defined in environment variables');
    }

    if (!authenticatedRoleArn) {
      throw new Error('authenticatedRoleArn is not defined in environment variables');
    }

    console.log(`Setting roles for identity pool ${identityPoolId}`);
    console.log(`Authenticated role: ${authenticatedRoleArn}`);

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
