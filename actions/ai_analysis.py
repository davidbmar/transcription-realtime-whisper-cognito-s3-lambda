"""
AI Analysis Action.

Generates AI analysis of transcript using Claude API.
Extracts: action items, key terms, themes, topic changes, highlights.

This wraps the existing scripts/lib/ai-analysis.py functionality.
"""

import json
import logging
from datetime import datetime
from typing import Dict

import anthropic

from .base import ActionBase, ActionResult
from .config import ANTHROPIC_API_KEY, DEFAULT_CLAUDE_MODEL

logger = logging.getLogger(__name__)


class AiAnalysisAction(ActionBase):
    """Generate AI analysis with action items, themes, and highlights."""

    name = 'ai-analysis'
    description = 'Generate AI analysis with action items, themes, and highlights'
    requires = ['transcription-processed.json']
    produces = ['transcription-ai-analysis.json', 'transcription-enhanced.json']

    def run(self, session_path: str, params: Dict) -> ActionResult:
        """
        Run AI analysis on transcript.

        Args:
            session_path: S3 path like users/123/audio/sessions/abc
            params: Optional params:
                - force: bool - Re-analyze even if output exists

        Returns:
            ActionResult with success status
        """
        force = params.get('force', False)

        # Check if analysis already exists
        if not force and self.file_exists(session_path, 'transcription-ai-analysis.json'):
            logger.info("Analysis already exists. Use force=True to re-analyze.")
            return ActionResult(
                success=True,
                outputs=self.produces,
                duration_seconds=self.elapsed(),
                metadata={'skipped': True, 'reason': 'already exists'}
            )

        # Load transcript
        transcript = self.load_file(session_path, 'transcription-processed.json')
        paragraphs = transcript.get('paragraphs', [])

        if not paragraphs:
            return ActionResult(
                success=False,
                outputs=[],
                duration_seconds=self.elapsed(),
                error="No paragraphs found in transcript"
            )

        # Format for Claude
        text = self._format_transcript(paragraphs)
        duration = transcript.get('stats', {}).get('totalDuration', 0)

        # Call Claude API
        analysis = self._generate_analysis(text, duration)
        if analysis is None:
            return ActionResult(
                success=False,
                outputs=[],
                duration_seconds=self.elapsed(),
                error="Failed to generate analysis with Claude"
            )

        # Save standalone analysis
        self.save_file(session_path, 'transcription-ai-analysis.json', analysis)

        # Save enhanced transcript (original + analysis)
        enhanced = {**transcript, 'aiAnalysis': analysis}
        self.save_file(session_path, 'transcription-enhanced.json', enhanced)

        return ActionResult(
            success=True,
            outputs=self.produces,
            duration_seconds=self.elapsed(),
            metadata={
                'actionItems': len(analysis.get('actionItems', [])),
                'keyTerms': len(analysis.get('keyTerms', [])),
                'keyThemes': len(analysis.get('keyThemes', [])),
                'topicChanges': len(analysis.get('topicChanges', [])),
                'highlights': len(analysis.get('highlights', [])),
                'tokens': analysis.get('_meta', {}).get('tokens', 0)
            }
        )

    def _format_transcript(self, paragraphs: list) -> str:
        """Format transcript paragraphs into text with timestamps."""
        lines = []
        for para in paragraphs:
            timestamp = self._format_time(para.get('start', 0))
            text = para.get('text', '')
            lines.append(f"[{timestamp}] {text}")
        return '\n\n'.join(lines)

    def _format_time(self, seconds: float) -> str:
        """Format seconds to MM:SS."""
        mins = int(seconds // 60)
        secs = int(seconds % 60)
        return f"{mins}:{secs:02d}"

    def _generate_analysis(self, transcript_text: str, total_duration: float) -> Dict:
        """Send transcript to Claude API for analysis."""
        if not ANTHROPIC_API_KEY:
            logger.error("ANTHROPIC_API_KEY not set")
            return None

        prompt = f"""Analyze this transcript and extract structured insights for intelligent video navigation.

TRANSCRIPT (Duration: {self._format_time(total_duration)}):
{transcript_text}

Generate a comprehensive JSON analysis with these exact categories:

1. **actionItems**: Find 5-10 explicit tasks, recommendations, or actionable steps mentioned
   - Include time codes (in seconds as float)
   - Brief summary (1 sentence)
   - Extract exact quote
   - Priority: "high", "medium", or "low"

2. **keyTerms**: Identify 8-15 technical terms, domain-specific vocabulary, important concepts
   - First mention only (don't repeat same term)
   - Include time codes
   - Brief definition or context

3. **keyThemes**: Identify 4-8 main topics or subjects discussed at length
   - Time ranges where theme is actively discussed (start and end)
   - Brief summary (2 sentences max)
   - Intensity score (0.0 to 1.0 based on depth/importance)

4. **topicChanges**: Find 6-12 points where speaker shifts to a new distinct subject
   - Exact time code of transition
   - What changed from/to
   - Type: "explicit" (announced) or "implicit" (natural shift)

5. **highlights**: Extract 8-15 most significant moments or key insights
   - Time ranges
   - Summary of the insight
   - Importance score (0.0 to 1.0)
   - Categories: ["insight", "prediction", "quote", "decision", "conclusion"]

IMPORTANT RULES:
- All time codes must be in SECONDS as float (e.g., 45.2, not "0:45")
- Parse timestamps from [MM:SS] format in transcript
- Return ONLY valid JSON, no markdown, no explanation

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
      "summary": "Extended comparison of evolutionary algorithms versus conventional software development",
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
            client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

            message = client.messages.create(
                model=DEFAULT_CLAUDE_MODEL,
                max_tokens=8000,
                messages=[{
                    "role": "user",
                    "content": prompt
                }]
            )

            response_text = message.content[0].text
            logger.info(f"Received response from Claude ({len(response_text)} chars)")

            # Parse JSON response
            analysis = json.loads(response_text)

            # Validate structure
            required_keys = ['actionItems', 'keyTerms', 'keyThemes', 'topicChanges', 'highlights']
            for key in required_keys:
                if key not in analysis:
                    logger.warning(f"Missing key in response: {key}")
                    analysis[key] = []

            # Add metadata
            analysis['_meta'] = {
                'version': '1.0',
                'generatedAt': datetime.utcnow().isoformat() + 'Z',
                'model': DEFAULT_CLAUDE_MODEL,
                'tokens': message.usage.input_tokens + message.usage.output_tokens,
                'cost_estimate': (message.usage.input_tokens * 0.25 + message.usage.output_tokens * 1.25) / 1_000_000,
                'action': self.name
            }

            logger.info(f"Analysis complete - Tokens: {analysis['_meta']['tokens']}")
            return analysis

        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse Claude response as JSON: {e}")
            return None
        except Exception as e:
            logger.error(f"Error calling Claude API: {e}")
            return None
