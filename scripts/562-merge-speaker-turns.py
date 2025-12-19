#!/usr/bin/env python3
"""
Merge Speaker Turns - Consolidate consecutive segments by speaker

Takes a diarized transcript and merges consecutive segments from the same
speaker into coherent paragraphs/turns. This makes transcripts much more
readable while preserving timestamps.

Usage:
    python3 scripts/562-merge-speaker-turns.py <transcript.json> [--update]

Input format (segments):
    [
        {"speaker": "SPEAKER_00", "text": "Hello.", "start": 0.0, "end": 1.0},
        {"speaker": "SPEAKER_00", "text": "How are you?", "start": 1.2, "end": 2.5},
        {"speaker": "SPEAKER_01", "text": "I'm good.", "start": 3.0, "end": 4.0}
    ]

Output format (merged turns):
    [
        {
            "speaker": "SPEAKER_00",
            "speaker_name": "Tim",
            "text": "Hello. How are you?",
            "start": 0.0,
            "end": 2.5,
            "segment_count": 2,
            "words": [...]  // Combined words array
        },
        {
            "speaker": "SPEAKER_01",
            "speaker_name": "Evenu",
            "text": "I'm good.",
            "start": 3.0,
            "end": 4.0,
            "segment_count": 1,
            "words": [...]
        }
    ]
"""

import json
import sys
import subprocess
import os
from datetime import datetime, timezone


def load_json(path):
    """Load JSON from local file or S3."""
    if path.startswith('s3://'):
        result = subprocess.run(
            ['aws', 's3', 'cp', path, '/tmp/input_merge.json'],
            capture_output=True
        )
        if result.returncode != 0:
            raise Exception(f"Failed to download from S3: {result.stderr.decode()}")
        path = '/tmp/input_merge.json'
    with open(path) as f:
        return json.load(f)


def save_json(data, path):
    """Save JSON to local file or S3."""
    if path.startswith('s3://'):
        with open('/tmp/output_merge.json', 'w') as f:
            json.dump(data, f, indent=2)
        result = subprocess.run(
            ['aws', 's3', 'cp', '/tmp/output_merge.json', path],
            capture_output=True
        )
        if result.returncode != 0:
            raise Exception(f"Failed to upload to S3: {result.stderr.decode()}")
    else:
        with open(path, 'w') as f:
            json.dump(data, f, indent=2)


def fix_chunk_relative_timestamps(segments, chunk_duration=120):
    """
    Detect and fix chunk-relative timestamps.

    WhisperX outputs timestamps relative to each audio chunk (0-120s).
    This function detects timestamp resets and converts to absolute session time.

    Detection: If segment N starts at time T where T < previous segment's end - 10s,
    it's likely the start of a new chunk.

    Fix: Add chunk_index * chunk_duration to all timestamps.

    Returns: (fixed_segments, chunks_detected)
    """
    if not segments:
        return segments, 0

    fixed_segments = []
    current_chunk = 0
    prev_end = 0

    for i, seg in enumerate(segments):
        seg_start = seg.get('start', 0)
        seg_end = seg.get('end', 0)

        # Detect chunk boundary: timestamp reset (start is much less than prev end)
        # Allow 10s tolerance for slight overlaps
        if i > 0 and seg_start < prev_end - 10:
            current_chunk += 1
            print(f"  [Timestamp Fix] Detected chunk boundary at segment {i}: "
                  f"prev_end={prev_end:.1f}s, new_start={seg_start:.1f}s -> chunk {current_chunk}")

        # Calculate offset for this chunk
        offset = current_chunk * chunk_duration

        # Create fixed segment with absolute timestamps
        fixed_seg = seg.copy()
        fixed_seg['start'] = seg_start + offset
        fixed_seg['end'] = seg_end + offset
        fixed_seg['chunk_index'] = current_chunk

        # Fix word timestamps too
        if fixed_seg.get('words'):
            fixed_words = []
            for word in fixed_seg['words']:
                fixed_word = word.copy()
                fixed_word['start'] = word.get('start', 0) + offset
                fixed_word['end'] = word.get('end', 0) + offset
                fixed_words.append(fixed_word)
            fixed_seg['words'] = fixed_words

        fixed_segments.append(fixed_seg)
        prev_end = seg_end  # Use original (relative) end for next comparison

    return fixed_segments, current_chunk + 1


def merge_speaker_turns(data):
    """
    Merge consecutive segments from the same speaker into turns.

    Returns a new data structure with:
    - paragraphs: merged speaker turns
    - speakers: list of unique speakers
    - speaker_names: mapping of speaker IDs to names
    - stats: paragraph count, word count, duration
    """
    segments = data.get('segments', [])

    # Fix chunk-relative timestamps before merging
    if segments:
        segments, chunks_detected = fix_chunk_relative_timestamps(segments)
        if chunks_detected > 1:
            print(f"  [Timestamp Fix] Fixed timestamps across {chunks_detected} chunks")
    speaker_names = data.get('speaker_names', {})

    if not segments:
        return data

    paragraphs = []
    current_turn = None

    for seg in segments:
        speaker = seg.get('speaker', 'Unknown')
        text = seg.get('text', '').strip()

        if not text:
            continue

        # Start new turn if speaker changed or first segment
        if current_turn is None or current_turn['speaker'] != speaker:
            # Save previous turn
            if current_turn is not None:
                paragraphs.append(current_turn)

            # Start new turn
            current_turn = {
                'speaker': speaker,
                'speaker_name': speaker_names.get(speaker, speaker),
                'text': text,
                'start': seg.get('start', 0),
                'end': seg.get('end', 0),
                'segment_count': 1,
                'words': seg.get('words', []).copy() if seg.get('words') else []
            }
        else:
            # Continue current turn - append text
            current_turn['text'] += ' ' + text
            current_turn['end'] = seg.get('end', current_turn['end'])
            current_turn['segment_count'] += 1

            # Append words
            if seg.get('words'):
                current_turn['words'].extend(seg['words'])

    # Don't forget the last turn
    if current_turn is not None:
        paragraphs.append(current_turn)

    # Add paragraph IDs
    for i, para in enumerate(paragraphs):
        para['id'] = f'p-{i}'

    # Calculate stats
    total_words = sum(len(p['text'].split()) for p in paragraphs)
    total_duration = paragraphs[-1]['end'] - paragraphs[0]['start'] if paragraphs else 0

    # Build result
    result = {
        'paragraphs': paragraphs,
        'speakers': list(set(p['speaker'] for p in paragraphs)),
        'speaker_names': speaker_names,
        'speaker_identification': data.get('speaker_identification'),
        'metadata': data.get('metadata', {}),
        'stats': {
            'paragraphCount': len(paragraphs),
            'originalSegmentCount': len(segments),
            'totalWords': total_words,
            'totalDuration': total_duration,
            'wordsPerMinute': round(total_words / (total_duration / 60)) if total_duration > 0 else 0,
            'compressionRatio': round(len(segments) / len(paragraphs), 1) if paragraphs else 0
        },
        'merge_metadata': {
            'merged_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
            'original_segment_count': len(segments),
            'merged_paragraph_count': len(paragraphs)
        }
    }

    return result


def print_preview(data):
    """Print a preview of the merged transcript."""
    paragraphs = data.get('paragraphs', [])
    speaker_names = data.get('speaker_names', {})

    print("\n" + "=" * 60)
    print("MERGED TRANSCRIPT PREVIEW")
    print("=" * 60)

    # Show first 5 turns
    for para in paragraphs[:5]:
        speaker = para.get('speaker', 'Unknown')
        name = speaker_names.get(speaker, speaker)
        text = para.get('text', '')[:100]
        seg_count = para.get('segment_count', 1)

        print(f"\n[{name}] ({seg_count} segments)")
        print(f"  {text}{'...' if len(para.get('text', '')) > 100 else ''}")

    if len(paragraphs) > 5:
        print(f"\n... and {len(paragraphs) - 5} more turns")

    print("\n" + "=" * 60)
    stats = data.get('stats', {})
    print(f"Original segments: {stats.get('originalSegmentCount', 'N/A')}")
    print(f"Merged paragraphs: {stats.get('paragraphCount', 'N/A')}")
    print(f"Compression ratio: {stats.get('compressionRatio', 'N/A')}x")
    print("=" * 60)


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 562-merge-speaker-turns.py <transcript.json> [--update]")
        print("\nOptions:")
        print("  --update    Update the file in place (or upload to S3)")
        print("\nExample:")
        print("  python3 scripts/562-merge-speaker-turns.py s3://bucket/path/transcription-diarized.json --update")
        return False

    transcript_path = sys.argv[1]
    update = '--update' in sys.argv

    # Load transcript
    print(f"Loading: {transcript_path}")
    data = load_json(transcript_path)

    # Check if already merged
    if data.get('merge_metadata'):
        print("Transcript already merged, skipping...")
        return True

    # Check for segments
    if not data.get('segments'):
        print("No segments found in transcript")
        return False

    print(f"Found {len(data['segments'])} segments")

    # Merge speaker turns
    print("Merging consecutive speaker turns...")
    merged = merge_speaker_turns(data)

    # Print preview
    print_preview(merged)

    # Save if requested
    if update:
        # Determine output path
        if transcript_path.endswith('transcription-diarized.json'):
            output_path = transcript_path.replace('transcription-diarized.json', 'transcription-processed.json')
        else:
            output_path = transcript_path

        print(f"\nSaving to: {output_path}")
        save_json(merged, output_path)
        print("Done!")
    else:
        print("\nDry run - use --update to save changes")

    return True


if __name__ == '__main__':
    sys.exit(0 if main() else 1)
