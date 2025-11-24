#!/usr/bin/env python3
"""
Script 520: Generate AI Analysis for Transcripts
Analyzes transcripts using Claude API to extract:
- Action Items
- Key Terms
- Key Themes
- Topic Changes
- Overall Highlights

This creates time-coded annotations for intelligent video navigation.
"""

import json
import os
import sys
import argparse
import boto3
from datetime import datetime
from typing import Dict, List, Optional
import anthropic

# Setup logging
import logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Load environment variables
from dotenv import load_dotenv
load_dotenv()

# AWS Configuration
AWS_REGION = os.getenv('AWS_REGION', 'us-east-2')
S3_BUCKET = os.getenv('COGNITO_S3_BUCKET', 'clouddrive-app-bucket')

# Claude API Configuration
ANTHROPIC_API_KEY = os.getenv('ANTHROPIC_API_KEY', '')

# Initialize clients
s3_client = boto3.client('s3', region_name=AWS_REGION)


def load_transcript_from_s3(session_path: str) -> Optional[Dict]:
    """
    Load processed transcript from S3

    Args:
        session_path: S3 path like users/{userId}/audio/sessions/{sessionId}

    Returns:
        Processed transcript data or None if not found
    """
    try:
        # Try preprocessed file first
        processed_key = f"{session_path}/transcription-processed.json"
        logger.info(f"Loading transcript from s3://{S3_BUCKET}/{processed_key}")

        response = s3_client.get_object(Bucket=S3_BUCKET, Key=processed_key)
        data = json.loads(response['Body'].read().decode('utf-8'))

        logger.info(f"Loaded transcript with {len(data.get('paragraphs', []))} paragraphs")
        return data

    except s3_client.exceptions.NoSuchKey:
        logger.error(f"Transcript not found: {processed_key}")
        return None
    except Exception as e:
        logger.error(f"Error loading transcript: {e}")
        return None


def format_transcript_for_analysis(transcript_data: Dict) -> str:
    """
    Format transcript into a readable text with timestamps for Claude

    Args:
        transcript_data: Processed transcript data

    Returns:
        Formatted text with timestamps
    """
    paragraphs = transcript_data.get('paragraphs', [])

    lines = []
    for i, para in enumerate(paragraphs):
        timestamp = format_time(para.get('start', 0))
        text = para.get('text', '')
        lines.append(f"[{timestamp}] {text}")

    return '\n\n'.join(lines)


def format_time(seconds: float) -> str:
    """Format seconds to MM:SS"""
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{mins}:{secs:02d}"


def generate_analysis_with_claude(transcript_text: str, total_duration: float) -> Optional[Dict]:
    """
    Send transcript to Claude API for analysis

    Args:
        transcript_text: Formatted transcript with timestamps
        total_duration: Total duration in seconds

    Returns:
        AI analysis data or None on error
    """
    if not ANTHROPIC_API_KEY:
        logger.error("ANTHROPIC_API_KEY not set in .env file")
        return None

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    prompt = f"""Analyze this transcript and extract structured insights for intelligent video navigation.

TRANSCRIPT (Duration: {format_time(total_duration)}):
{transcript_text}

Generate a comprehensive JSON analysis with these exact categories:

1. **actionItems**: Explicit tasks, recommendations, or actionable steps mentioned
   - Include time codes (in seconds as float)
   - Brief summary (1 sentence)
   - Extract exact quote
   - Priority: "high", "medium", or "low"

2. **keyTerms**: Technical terms, domain-specific vocabulary, important concepts
   - First mention only (don't repeat same term)
   - Include time codes
   - Brief definition or context
   - Mark as firstMention: true

3. **keyThemes**: Main topics or subjects discussed at length
   - Time ranges where theme is actively discussed (start and end)
   - Brief summary (2 sentences max)
   - Intensity score (0.0 to 1.0 based on depth/importance)

4. **topicChanges**: Points where speaker shifts to a new distinct subject
   - Exact time code of transition
   - What changed from/to
   - Type: "explicit" (announced) or "implicit" (natural shift)

5. **highlights**: Top 5-10 most significant moments or key insights
   - Time ranges
   - Summary of the insight
   - Importance score (0.0 to 1.0)
   - Categories: ["insight", "prediction", "quote", "decision", "conclusion"]

IMPORTANT RULES:
- All time codes must be in SECONDS as float (e.g., 45.2, not "0:45")
- Parse timestamps from [MM:SS] format in transcript
- Return ONLY valid JSON, no markdown, no explanation
- Be selective - quality over quantity
- Focus on what would help someone navigate and understand the content quickly

Expected JSON format:
{{
  "actionItems": [
    {{
      "timeCodeStart": 59.0,
      "timeCodeEnd": 68.5,
      "summary": "Focus on evolutionary optimization over traditional coding",
      "text": "We need to shift our approach to evolutionary algorithms",
      "priority": "high"
    }}
  ],
  "keyTerms": [
    {{
      "timeCodeStart": 47.0,
      "timeCodeEnd": 51.0,
      "term": "Reinforcement Learning",
      "definition": "ML technique using rewards and penalties for optimization",
      "context": "Discussion of AI training methodologies",
      "firstMention": true
    }}
  ],
  "keyThemes": [
    {{
      "timeCodeStart": 120.0,
      "timeCodeEnd": 245.0,
      "theme": "Evolution vs Traditional Programming",
      "summary": "Extended comparison of evolutionary algorithms versus conventional software development approaches",
      "intensity": 0.89
    }}
  ],
  "topicChanges": [
    {{
      "timeCode": 32.5,
      "fromTopic": "Introduction",
      "toTopic": "AI Development Timeline",
      "transitionType": "explicit"
    }}
  ],
  "highlights": [
    {{
      "timeCodeStart": 180.0,
      "timeCodeEnd": 195.0,
      "summary": "Key insight about why agent systems require decade-scale development",
      "importance": 0.95,
      "categories": ["insight", "prediction"]
    }}
  ]
}}

Return ONLY the JSON object, nothing else."""

    try:
        logger.info("Sending transcript to Claude for analysis...")

        message = client.messages.create(
            model="claude-3-5-haiku-20241022",  # Using Haiku for cost efficiency
            max_tokens=8000,
            messages=[{
                "role": "user",
                "content": prompt
            }]
        )

        response_text = message.content[0].text
        logger.info(f"Received response from Claude ({len(response_text)} chars)")

        # Parse JSON response
        analysis_data = json.loads(response_text)

        # Validate structure
        required_keys = ['actionItems', 'keyTerms', 'keyThemes', 'topicChanges', 'highlights']
        for key in required_keys:
            if key not in analysis_data:
                logger.warning(f"Missing key in response: {key}")
                analysis_data[key] = []

        # Add metadata
        analysis_data['_meta'] = {
            'version': '1.0',
            'generatedAt': datetime.utcnow().isoformat() + 'Z',
            'model': 'claude-haiku-4',
            'tokens': message.usage.input_tokens + message.usage.output_tokens,
            'cost_estimate': (message.usage.input_tokens * 0.25 + message.usage.output_tokens * 1.25) / 1_000_000
        }

        logger.info(f"Analysis complete - Tokens: {analysis_data['_meta']['tokens']}, Cost: ${analysis_data['_meta']['cost_estimate']:.4f}")
        logger.info(f"  Action Items: {len(analysis_data['actionItems'])}")
        logger.info(f"  Key Terms: {len(analysis_data['keyTerms'])}")
        logger.info(f"  Key Themes: {len(analysis_data['keyThemes'])}")
        logger.info(f"  Topic Changes: {len(analysis_data['topicChanges'])}")
        logger.info(f"  Highlights: {len(analysis_data['highlights'])}")

        return analysis_data

    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Claude response as JSON: {e}")
        logger.error(f"Response text: {response_text[:500]}...")
        return None
    except Exception as e:
        logger.error(f"Error calling Claude API: {e}")
        return None


def save_analysis_to_s3(session_path: str, analysis_data: Dict) -> bool:
    """
    Save AI analysis to S3

    Args:
        session_path: S3 path like users/{userId}/audio/sessions/{sessionId}
        analysis_data: AI analysis data to save

    Returns:
        True if successful
    """
    try:
        analysis_key = f"{session_path}/transcription-ai-analysis.json"

        logger.info(f"Saving analysis to s3://{S3_BUCKET}/{analysis_key}")

        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=analysis_key,
            Body=json.dumps(analysis_data, indent=2).encode('utf-8'),
            ContentType='application/json'
        )

        logger.info("✅ Analysis saved successfully")
        return True

    except Exception as e:
        logger.error(f"Error saving analysis to S3: {e}")
        return False


def merge_analysis_into_transcript(transcript_data: Dict, analysis_data: Dict) -> Dict:
    """
    Merge AI analysis into the processed transcript

    Args:
        transcript_data: Original processed transcript
        analysis_data: AI analysis data

    Returns:
        Enhanced transcript with AI analysis embedded
    """
    enhanced = transcript_data.copy()
    enhanced['aiAnalysis'] = analysis_data
    return enhanced


def save_enhanced_transcript(session_path: str, enhanced_data: Dict) -> bool:
    """
    Save enhanced transcript (original + AI analysis) to S3

    Args:
        session_path: S3 path
        enhanced_data: Enhanced transcript data

    Returns:
        True if successful
    """
    try:
        enhanced_key = f"{session_path}/transcription-enhanced.json"

        logger.info(f"Saving enhanced transcript to s3://{S3_BUCKET}/{enhanced_key}")

        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=enhanced_key,
            Body=json.dumps(enhanced_data, indent=2).encode('utf-8'),
            ContentType='application/json'
        )

        logger.info("✅ Enhanced transcript saved successfully")
        return True

    except Exception as e:
        logger.error(f"Error saving enhanced transcript: {e}")
        return False


def process_session(session_path: str, force: bool = False) -> bool:
    """
    Process a single session

    Args:
        session_path: S3 path like users/{userId}/audio/sessions/{sessionId}
        force: Re-analyze even if analysis already exists

    Returns:
        True if successful
    """
    logger.info(f"\n{'='*60}")
    logger.info(f"Processing session: {session_path}")
    logger.info(f"{'='*60}\n")

    # Check if analysis already exists
    if not force:
        try:
            analysis_key = f"{session_path}/transcription-ai-analysis.json"
            s3_client.head_object(Bucket=S3_BUCKET, Key=analysis_key)
            logger.info("⚠️  Analysis already exists. Use --force to re-analyze.")
            return True
        except s3_client.exceptions.ClientError:
            pass  # Analysis doesn't exist, proceed

    # Load transcript
    transcript_data = load_transcript_from_s3(session_path)
    if not transcript_data:
        return False

    # Format for analysis
    transcript_text = format_transcript_for_analysis(transcript_data)
    total_duration = transcript_data.get('stats', {}).get('totalDuration', 0)

    # Generate analysis with Claude
    analysis_data = generate_analysis_with_claude(transcript_text, total_duration)
    if not analysis_data:
        return False

    # Save standalone analysis
    if not save_analysis_to_s3(session_path, analysis_data):
        return False

    # Merge and save enhanced transcript
    enhanced_data = merge_analysis_into_transcript(transcript_data, analysis_data)
    if not save_enhanced_transcript(session_path, enhanced_data):
        return False

    logger.info(f"\n✅ Session analysis complete!")
    return True


def main():
    parser = argparse.ArgumentParser(
        description='Generate AI analysis for CloudDrive transcripts'
    )
    parser.add_argument(
        '--session-path',
        required=True,
        help='S3 path to session (e.g., users/abc123/audio/sessions/session_2025-11-24T10_30_00_000Z)'
    )
    parser.add_argument(
        '--force',
        action='store_true',
        help='Re-analyze even if analysis already exists'
    )

    args = parser.parse_args()

    if not ANTHROPIC_API_KEY:
        logger.error("ERROR: ANTHROPIC_API_KEY not set in .env file")
        logger.error("Please add: ANTHROPIC_API_KEY=your-api-key-here")
        sys.exit(1)

    success = process_session(args.session_path, args.force)

    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
