"""
Actions System Configuration.
Follows the same pattern as existing scripts - loads from project .env file.
"""

import os
from pathlib import Path

from dotenv import load_dotenv

# Load .env from project root (same as scripts/lib/ai-analysis.py)
PROJECT_ROOT = Path(__file__).parent.parent
load_dotenv(PROJECT_ROOT / '.env')

# AWS Configuration (from .env)
AWS_REGION = os.getenv('AWS_REGION', 'us-east-2')
S3_BUCKET = os.getenv('COGNITO_S3_BUCKET', 'clouddrive-app-bucket')

# API Keys (from .env)
ANTHROPIC_API_KEY = os.getenv('ANTHROPIC_API_KEY', '')

# Embedding Model (from .env - used by topics action)
EMBEDDING_MODEL = os.getenv('EMBEDDING_MODEL_ID', 'amazon.titan-embed-text-v2:0')
EMBEDDING_DIMS = int(os.getenv('EMBEDDING_DIMENSIONS', '1024'))
TOPIC_THRESHOLD = float(os.getenv('TOPIC_SIMILARITY_THRESHOLD', '0.20'))

# Model Defaults
DEFAULT_CLAUDE_MODEL = 'claude-3-5-haiku-20241022'
