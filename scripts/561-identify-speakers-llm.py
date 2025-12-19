#!/usr/bin/env python3
"""
LLM-based Speaker Identification - Works on ANY transcript

Sends transcript samples to Claude to identify speakers
based on context clues in the conversation.

Usage:
    python3 scripts/561-identify-speakers-llm.py <transcript.json> [--update]
"""

import json
import sys
import subprocess
import os
import re

def load_json(path):
    """Load JSON from local file or S3."""
    if path.startswith('s3://'):
        subprocess.run(['aws', 's3', 'cp', path, '/tmp/input.json'], 
                      capture_output=True, check=True)
        path = '/tmp/input.json'
    with open(path) as f:
        return json.load(f)

def format_for_llm(data, max_chars=12000):
    """Sample segments from throughout the transcript to capture all speakers."""
    segments = data.get('segments', [])
    
    # Find all unique speakers and when they first appear
    speaker_first_seg = {}
    for i, seg in enumerate(segments):
        speaker = seg.get('speaker', 'Unknown')
        if speaker not in speaker_first_seg:
            speaker_first_seg[speaker] = i
    
    # Include: first 30 segments + first appearance of each speaker + surrounding context
    indices_to_include = set(range(min(30, len(segments))))
    
    for speaker, first_idx in speaker_first_seg.items():
        # Add context around first appearance (5 before, 10 after)
        for i in range(max(0, first_idx - 5), min(len(segments), first_idx + 10)):
            indices_to_include.add(i)
    
    # Format selected segments
    lines = []
    total_chars = 0
    for i in sorted(indices_to_include):
        seg = segments[i]
        speaker = seg.get('speaker', 'Unknown')
        text = seg.get('text', '').strip()
        start = seg.get('start', 0)
        mins, secs = int(start // 60), int(start % 60)
        line = f"[{mins}:{secs:02d}] {speaker}: {text}"
        
        if total_chars + len(line) > max_chars:
            break
        lines.append(line)
        total_chars += len(line)
    
    return '\n'.join(lines)

def identify_speakers(transcript_text):
    """Call Claude API to identify speakers."""
    import anthropic
    
    client = anthropic.Anthropic()
    
    prompt = f"""Analyze this meeting transcript and identify who each speaker really is.

Look for clues like:
- Self-identification: "This is John speaking" or "I'm Sarah"
- Addressing others: "Hey Mike, what do you think?" or "Ryan, your thoughts?"
- References: "As Tim mentioned earlier..." or "what Tim described"
- Response patterns: If someone says "Ryan?" and the next speaker responds

TRANSCRIPT:
{transcript_text}

Return ONLY valid JSON (no markdown, no explanation):
{{
    "speakers": {{
        "SPEAKER_XX": {{
            "name": "RealName or null if unknown",
            "confidence": "high/medium/low",
            "evidence": "brief quote or reason"
        }}
    }}
}}"""

    response = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}]
    )
    
    text = response.content[0].text
    match = re.search(r'\{[\s\S]*\}', text)
    if match:
        return json.loads(match.group())
    return None

def apply_names(data, result):
    """Apply identified names to transcript.

    Adds 'speaker_names' field that the UI reads to display real names.
    Format: {"SPEAKER_00": "Tim", "SPEAKER_01": "Ryan", ...}
    """
    updated = json.loads(json.dumps(data))

    # Build speaker_names mapping for UI
    speaker_names = {}
    speaker_info = result.get('speakers', {})

    for speaker_id, info in speaker_info.items():
        name = info.get('name')
        if name:  # Only add if we identified a name
            speaker_names[speaker_id] = name

    # Add to transcript root (UI reads this)
    updated['speaker_names'] = speaker_names

    # Also store full identification info for debugging
    updated['speaker_identification'] = {
        'method': 'llm',
        'identified_at': subprocess.run(['date', '-u', '+%Y-%m-%dT%H:%M:%SZ'],
                                        capture_output=True, text=True).stdout.strip(),
        'details': speaker_info
    }

    return updated

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 561-identify-speakers-llm.py <transcript.json> [--update] [--output path]")
        sys.exit(1)

    if not os.environ.get('ANTHROPIC_API_KEY'):
        print("Error: Set ANTHROPIC_API_KEY environment variable")
        sys.exit(1)

    transcript_path = sys.argv[1]
    update = '--update' in sys.argv

    # Parse --output flag
    output_path = None
    if '--output' in sys.argv:
        idx = sys.argv.index('--output')
        if idx + 1 < len(sys.argv):
            output_path = sys.argv[idx + 1]

    data = load_json(transcript_path)
    transcript_text = format_for_llm(data)

    print("Sending to Claude for analysis...")
    result = identify_speakers(transcript_text)

    if result:
        print("\n" + "=" * 60)
        print("IDENTIFIED SPEAKERS")
        print("=" * 60)

        identified_count = 0
        for speaker_id, info in result.get('speakers', {}).items():
            name = info.get('name')
            conf = info.get('confidence', '?')
            evidence = info.get('evidence', '')
            display_name = name or 'Unknown'
            print(f"\n{speaker_id} -> {display_name} ({conf})")
            print(f"  Evidence: {evidence[:80]}")
            if name:
                identified_count += 1

        print("\n" + "=" * 60)
        print(f"Identified {identified_count} speakers")

        if update:
            updated = apply_names(data, result)

            # Default output path: same as input (overwrite with speaker_names added)
            if not output_path:
                output_path = transcript_path

            if output_path.startswith('s3://'):
                # Save to S3
                with open('/tmp/transcript-with-speakers.json', 'w') as f:
                    json.dump(updated, f)
                subprocess.run(['aws', 's3', 'cp', '/tmp/transcript-with-speakers.json',
                               output_path, '--quiet'], check=True)
            else:
                with open(output_path, 'w') as f:
                    json.dump(updated, f)

            print(f"Updated: {output_path}")
            return identified_count

    return 0

if __name__ == '__main__':
    sys.exit(0 if main() else 1)
