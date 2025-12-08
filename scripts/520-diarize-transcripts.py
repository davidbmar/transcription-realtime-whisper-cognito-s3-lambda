#!/usr/bin/env python3
"""
520: Diarize Transcripts - Add Speaker Labels to Transcriptions

This script runs on the GPU instance and adds speaker diarization to transcribed
sessions. It uses pyannote.audio to identify speakers and assigns labels to
each transcript segment.

Usage:
    # Diarize all sessions missing diarization
    python3 520-diarize-transcripts.py

    # Diarize specific session
    python3 520-diarize-transcripts.py --session users/abc123/audio/sessions/2025-12-01-session1

    # Backfill all existing sessions (ignore existing diarization)
    python3 520-diarize-transcripts.py --backfill

    # Dry run (list sessions that would be processed)
    python3 520-diarize-transcripts.py --dry-run

Prerequisites:
    - Must run on GPU instance with CUDA
    - pyannote-audio installed: pip install pyannote-audio
    - Pre-cached models in ~/.cache/huggingface/ (no HF_TOKEN needed)
    - ffmpeg installed for audio concatenation
    - AWS credentials configured

Performance:
    - ~4.5 min processing for 48 min audio (~0.1x realtime)
    - Loads model once, processes all sessions in sequence
"""

import os
import sys
import json
import argparse
import subprocess
import tempfile
import time
from pathlib import Path
from datetime import datetime

# Add scripts/lib to path for diarization module
SCRIPT_DIR = Path(__file__).parent.resolve()
sys.path.insert(0, str(SCRIPT_DIR / 'lib'))


def get_s3_bucket():
    """Get S3 bucket from environment or .env file"""
    bucket = os.environ.get('COGNITO_S3_BUCKET')
    if bucket:
        return bucket

    # Try to load from .env file
    env_file = SCRIPT_DIR.parent / '.env'
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                if line.startswith('COGNITO_S3_BUCKET='):
                    return line.split('=', 1)[1].strip().strip('"\'')

    raise ValueError("COGNITO_S3_BUCKET not set in environment or .env file")


def list_sessions_needing_diarization(bucket, backfill=False):
    """
    Find sessions with transcription but no diarization.

    Returns list of session paths (e.g., users/abc123/audio/sessions/2025-12-01-session1)
    """
    print("[INFO] Scanning S3 for sessions needing diarization...")

    # List all transcription-processed.json files
    result = subprocess.run(
        ['aws', 's3', 'ls', f's3://{bucket}/users/', '--recursive'],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        print(f"[ERROR] Failed to list S3: {result.stderr}", file=sys.stderr)
        return []

    # Parse output to find sessions with transcription
    sessions_with_transcription = set()
    sessions_with_diarization = set()

    for line in result.stdout.strip().split('\n'):
        if not line.strip():
            continue
        # Format: "2025-12-01 12:00:00  12345 users/abc/audio/sessions/xxx/file.json"
        parts = line.split()
        if len(parts) >= 4:
            key = parts[3]
            if 'transcription-processed.json' in key:
                session = '/'.join(key.split('/')[:-1])
                sessions_with_transcription.add(session)
            elif 'transcription-diarized.json' in key:
                session = '/'.join(key.split('/')[:-1])
                sessions_with_diarization.add(session)

    if backfill:
        # Process all sessions with transcription
        pending = sessions_with_transcription
    else:
        # Only process sessions without diarization
        pending = sessions_with_transcription - sessions_with_diarization

    sessions = sorted(list(pending))
    print(f"[INFO] Found {len(sessions_with_transcription)} transcribed sessions")
    print(f"[INFO] Found {len(sessions_with_diarization)} already diarized")
    print(f"[INFO] Pending diarization: {len(sessions)}")

    return sessions


def download_session_audio(bucket, session_path, work_dir):
    """
    Download all audio chunks for a session and concatenate them.

    Returns path to concatenated audio file, or None on failure.
    """
    print(f"[INFO] Downloading audio chunks from {session_path}...")

    # Create temp directory for chunks
    chunks_dir = Path(work_dir) / 'chunks'
    chunks_dir.mkdir(exist_ok=True)

    # Download all chunk-*.webm files
    result = subprocess.run(
        ['aws', 's3', 'sync',
         f's3://{bucket}/{session_path}/', str(chunks_dir),
         '--exclude', '*',
         '--include', 'chunk-*.webm',
         '--include', 'chunk-*.aac',
         '--include', 'chunk-*.m4a'],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        print(f"[ERROR] Failed to download chunks: {result.stderr}", file=sys.stderr)
        return None

    # Find all downloaded chunks and sort them
    chunk_files = sorted(
        [f for f in chunks_dir.iterdir() if f.name.startswith('chunk-')],
        key=lambda x: int(x.stem.split('-')[1]) if x.stem.split('-')[1].isdigit() else 0
    )

    if not chunk_files:
        print(f"[WARN] No audio chunks found for {session_path}")
        return None

    print(f"[INFO] Found {len(chunk_files)} audio chunks")

    # Concatenate chunks using ffmpeg
    output_audio = Path(work_dir) / 'combined.wav'

    # Create concat file for ffmpeg
    concat_file = Path(work_dir) / 'concat.txt'
    with open(concat_file, 'w') as f:
        for chunk in chunk_files:
            f.write(f"file '{chunk}'\n")

    # Concatenate and convert to WAV (16kHz mono, best for diarization)
    result = subprocess.run([
        'ffmpeg', '-y', '-f', 'concat', '-safe', '0',
        '-i', str(concat_file),
        '-ar', '16000', '-ac', '1',  # 16kHz mono
        '-c:a', 'pcm_s16le',  # 16-bit PCM
        str(output_audio)
    ], capture_output=True, text=True)

    if result.returncode != 0:
        print(f"[ERROR] ffmpeg concat failed: {result.stderr}", file=sys.stderr)
        return None

    # Get audio duration
    probe_result = subprocess.run([
        'ffprobe', '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        str(output_audio)
    ], capture_output=True, text=True)

    if probe_result.returncode == 0:
        duration = float(probe_result.stdout.strip())
        print(f"[INFO] Combined audio: {duration:.1f}s ({duration/60:.1f} min)")

    return str(output_audio)


def download_transcription(bucket, session_path, work_dir):
    """
    Download transcription for the session.

    Prefers raw chunk files (transcription-chunk-*.json) which have proper
    per-utterance segments. Falls back to transcription-processed.json.

    Returns list of segments, or None on failure.
    """
    print(f"[INFO] Downloading transcription from {session_path}...")

    work_path = Path(work_dir)

    # First, try to find and download transcription-chunk-*.json files
    list_result = subprocess.run(
        ['aws', 's3', 'ls', f's3://{bucket}/{session_path}/'],
        capture_output=True, text=True
    )

    if list_result.returncode == 0:
        chunk_files = []
        for line in list_result.stdout.strip().split('\n'):
            if 'transcription-chunk-' in line and '.json' in line:
                # Extract filename from "2025-12-01 12:00:00  12345 filename.json"
                parts = line.split()
                if len(parts) >= 4:
                    chunk_files.append(parts[3])

        if chunk_files:
            # Sort chunk files to ensure correct order
            chunk_files.sort()
            print(f"[INFO] Found {len(chunk_files)} chunk file(s): {chunk_files}")

            all_segments = []
            for chunk_file in chunk_files:
                chunk_path = work_path / chunk_file
                dl_result = subprocess.run(
                    ['aws', 's3', 'cp',
                     f's3://{bucket}/{session_path}/{chunk_file}',
                     str(chunk_path)],
                    capture_output=True, text=True
                )

                if dl_result.returncode == 0:
                    with open(chunk_path) as f:
                        data = json.load(f)

                    # Handle both array format and object with segments
                    if isinstance(data, list):
                        all_segments.extend(data)
                    elif 'segments' in data:
                        all_segments.extend(data['segments'])
                    else:
                        all_segments.extend(data.get('segments', [data]))

            if all_segments:
                print(f"[INFO] Loaded {len(all_segments)} segments from chunk files")
                return all_segments

    # Fallback: try transcription-processed.json
    print("[INFO] No chunk files found, trying transcription-processed.json...")
    trans_file = work_path / 'transcription.json'

    result = subprocess.run(
        ['aws', 's3', 'cp',
         f's3://{bucket}/{session_path}/transcription-processed.json',
         str(trans_file)],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        print(f"[ERROR] Failed to download transcription: {result.stderr}", file=sys.stderr)
        return None

    with open(trans_file) as f:
        data = json.load(f)

    # Extract segments from processed format
    # Format: {"paragraphs": [{"text": "...", "startTime": 0.0, "endTime": 1.5, "words": [...]}]}
    if 'paragraphs' in data:
        segments = []
        for para in data['paragraphs']:
            seg = {
                'text': para.get('text', ''),
                'start': para.get('startTime', 0),
                'end': para.get('endTime', 0),
                'words': para.get('words', [])
            }
            segments.append(seg)
        return segments
    elif 'segments' in data:
        return data['segments']
    elif isinstance(data, list):
        return data
    else:
        print(f"[ERROR] Unknown transcription format", file=sys.stderr)
        return None


def check_skip_diarization(bucket, session_path):
    """Check if session metadata has skipDiarization flag."""
    result = subprocess.run(
        ['aws', 's3', 'cp',
         f's3://{bucket}/{session_path}/metadata.json', '-'],
        capture_output=True, text=True
    )

    if result.returncode == 0:
        try:
            metadata = json.loads(result.stdout)
            if metadata.get('skipDiarization'):
                return True, metadata.get('skipReason', 'user-requested')
        except json.JSONDecodeError:
            pass

    return False, None


def upload_diarized_transcript(bucket, session_path, result):
    """Upload diarization result to S3."""
    print(f"[INFO] Uploading diarized transcript to {session_path}...")

    # Save to temp file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
        temp_file = f.name

    try:
        upload_result = subprocess.run(
            ['aws', 's3', 'cp', temp_file,
             f's3://{bucket}/{session_path}/transcription-diarized.json',
             '--content-type', 'application/json'],
            capture_output=True, text=True
        )

        if upload_result.returncode != 0:
            print(f"[ERROR] Failed to upload: {upload_result.stderr}", file=sys.stderr)
            return False

        print(f"[INFO] Uploaded transcription-diarized.json")
        return True

    finally:
        os.unlink(temp_file)


def process_session(diarizer, bucket, session_path, work_dir):
    """
    Process a single session: download, diarize, upload.

    Returns True on success, False on failure.
    """
    session_name = session_path.split('/')[-1]
    print(f"\n{'='*60}")
    print(f"[SESSION] {session_name}")
    print(f"{'='*60}")

    # Check for skip flag
    should_skip, skip_reason = check_skip_diarization(bucket, session_path)
    if should_skip:
        print(f"[INFO] Skipping diarization: {skip_reason}")
        return True

    # Create session work directory
    session_work_dir = Path(work_dir) / session_name
    session_work_dir.mkdir(exist_ok=True)

    try:
        # Download audio
        audio_path = download_session_audio(bucket, session_path, session_work_dir)
        if not audio_path:
            return False

        # Download transcription
        segments = download_transcription(bucket, session_path, session_work_dir)
        if not segments:
            return False

        print(f"[INFO] Transcription has {len(segments)} segments")

        # Run diarization
        result = diarizer.process(audio_path, segments)

        # Check if single speaker (might want to mark for skip in future)
        if len(result['speakers']) == 1:
            print(f"[INFO] Single speaker detected - diarization still saved")

        # Upload result
        if not upload_diarized_transcript(bucket, session_path, result):
            return False

        print(f"[SUCCESS] Diarized {session_name}: {len(result['speakers'])} speakers")
        return True

    except Exception as e:
        print(f"[ERROR] Failed to process {session_name}: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return False


def main():
    parser = argparse.ArgumentParser(
        description='Add speaker diarization to transcribed sessions',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument('--session', help='Process specific session (ID or full path)')
    parser.add_argument('--user', help='User ID (required with --session if providing session ID only)')
    parser.add_argument('--backfill', action='store_true',
                        help='Process ALL sessions (ignore existing diarization)')
    parser.add_argument('--dry-run', action='store_true',
                        help='List sessions that would be processed without processing')
    parser.add_argument('--max-sessions', type=int, default=0,
                        help='Maximum number of sessions to process (0=unlimited)')
    args = parser.parse_args()

    print("=" * 60)
    print("520: Diarize Transcripts")
    print("=" * 60)
    print(f"Started: {datetime.now().isoformat()}")
    print()

    # Get S3 bucket
    try:
        bucket = get_s3_bucket()
        print(f"[INFO] S3 Bucket: {bucket}")
    except ValueError as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)

    # Get sessions to process
    if args.session:
        session_input = args.session
        # Check if it's a full path or just session ID
        if session_input.startswith('users/'):
            # Full path provided
            sessions = [session_input]
        else:
            # Just session ID - need user ID to construct path
            if args.user:
                session_path = f"users/{args.user}/audio/sessions/{session_input}"
                sessions = [session_path]
                print(f"[INFO] Constructed session path: {session_path}")
            else:
                # Try to find the session by scanning
                print(f"[INFO] Searching for session {session_input}...")
                all_sessions = list_sessions_needing_diarization(bucket, backfill=True)
                matching = [s for s in all_sessions if session_input in s]
                if matching:
                    sessions = matching
                    print(f"[INFO] Found {len(matching)} matching session(s)")
                else:
                    print(f"[ERROR] Session not found: {session_input}", file=sys.stderr)
                    print("[HINT] Provide --user USER_ID to specify user", file=sys.stderr)
                    sys.exit(1)
    else:
        sessions = list_sessions_needing_diarization(bucket, backfill=args.backfill)

    if not sessions:
        print("[INFO] No sessions need diarization")
        sys.exit(0)

    if args.max_sessions > 0:
        sessions = sessions[:args.max_sessions]
        print(f"[INFO] Limited to {args.max_sessions} sessions")

    if args.dry_run:
        print(f"\n[DRY-RUN] Would process {len(sessions)} sessions:")
        for s in sessions:
            print(f"  - {s}")
        sys.exit(0)

    # Initialize diarizer (loads model once)
    print("\n[INFO] Initializing diarizer...")
    start_time = time.time()

    try:
        from diarization import OfflineDiarizer
        diarizer = OfflineDiarizer()
    except ImportError as e:
        print(f"[ERROR] Failed to import diarization module: {e}", file=sys.stderr)
        print("[HINT] Make sure pyannote-audio is installed:", file=sys.stderr)
        print("       pip install pyannote-audio", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[ERROR] Failed to initialize diarizer: {e}", file=sys.stderr)
        sys.exit(1)

    model_load_time = time.time() - start_time
    print(f"[INFO] Model loaded in {model_load_time:.1f}s")

    # Process sessions
    success_count = 0
    fail_count = 0

    with tempfile.TemporaryDirectory() as work_dir:
        for i, session_path in enumerate(sessions, 1):
            print(f"\n[PROGRESS] Processing session {i}/{len(sessions)}")

            if process_session(diarizer, bucket, session_path, work_dir):
                success_count += 1
            else:
                fail_count += 1

    # Summary
    total_time = time.time() - start_time
    print("\n" + "=" * 60)
    print("DIARIZATION COMPLETE")
    print("=" * 60)
    print(f"Total sessions: {len(sessions)}")
    print(f"Successful: {success_count}")
    print(f"Failed: {fail_count}")
    print(f"Total time: {total_time:.1f}s ({total_time/60:.1f} min)")
    print(f"Finished: {datetime.now().isoformat()}")

    sys.exit(0 if fail_count == 0 else 1)


if __name__ == '__main__':
    main()
