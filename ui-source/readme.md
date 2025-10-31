# IMPORTANT NOTES ON APP.JS FILE


## Development Workflow

This project uses a template approach to handle environment-specific configuration:

- `web/app.js.template` contains placeholders for AWS resource identifiers
- `deploy.sh` generates `web/app.js` with actual values during deployment
- **IMPORTANT**: Do not edit `web/app.js` directly; modify the template instead

### Making Changes

1. Edit `web/app.js.template` (not `web/app.js`) for frontend changes
2. Edit other source files as needed
3. Run `./deploy.sh` to deploy changes
4. Access your application via the CloudFront URL

### Key Files

- `serverless.yml` - Infrastructure as code defining all AWS resources
- `web/app.js.template` - Frontend JavaScript template with placeholders
- `web/index.html` - Main HTML file
- `api/handler.js` - Lambda function handling API requests
- `deploy.sh` - Deployment script that sets up everything

## Troubleshooting

- **Authentication Issues**: Check if the Cognito domain is correctly set up
- **API Access Denied**: Verify IAM roles and Cognito authorizers
- **CloudFront Errors**: May take several minutes to deploy; check invalidations
- **Login Fails**: Ensure app.js has the correct Cognito domain and client ID

## Notes

- The CloudFront distribution may take 5-10 minutes to fully deploy
- You must create at least one user in your Cognito User Pool to test authentication
- Never commit `web/app.js` to version control; it contains environment-specific values

## License

[Your license information here]
