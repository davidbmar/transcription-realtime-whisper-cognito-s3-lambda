#!/usr/bin/env python3
"""
GPU Batch Transcription Script
Loads WhisperModel ONCE and processes multiple audio files in sequence.
This eliminates the overhead of model loading for each file.

Usage:
    python3 batch-transcribe-audio-bulk.py --input /path/to/audio/dir --output /path/to/output/dir

Performance:
    - Current (1 file per script run): 15-18s per chunk (includes model load overhead)
    - Batch (N files per script run): ~5-8s per chunk after initial model load
"""

import sys
import json
import glob
import argparse
import time
from pathlib import Path

# WhisperLive/faster-whisper imports
try:
    from faster_whisper import WhisperModel
except ImportError:
    print("ERROR: faster-whisper not installed", file=sys.stderr)
    print("Install: pip install faster-whisper", file=sys.stderr)
    sys.exit(1)


def transcribe_file(model, audio_path, output_path):
    """Transcribe a single audio file using pre-loaded model"""
    start_time = time.time()

    try:
        # Transcribe with word timestamps
        segments_iterator, info = model.transcribe(
            audio_path,
            beam_size=5,
            word_timestamps=True,
            vad_filter=True,
            vad_parameters=dict(min_silence_duration_ms=500)
        )

        # Format output matching WhisperLive format
        result = {"segments": []}

        for segment in segments_iterator:
            seg_data = {
                "text": segment.text,
                "start": segment.start,
                "end": segment.end,
                "is_final": True,
                "words": []
            }

            # Add word-level timestamps
            if segment.words:
                for word in segment.words:
                    word_data = {
                        "word": word.word,
                        "start": word.start,
                        "end": word.end,
                        "probability": word.probability
                    }
                    seg_data["words"].append(word_data)

            result["segments"].append(seg_data)

        # Save output
        with open(output_path, 'w') as f:
            json.dump(result, f, indent=2)

        elapsed = time.time() - start_time
        return True, elapsed, len(result["segments"])

    except Exception as e:
        print(f"ERROR transcribing {audio_path}: {e}", file=sys.stderr)
        return False, 0, 0


def main():
    parser = argparse.ArgumentParser(description='Batch transcribe audio files')
    parser.add_argument('--input', required=True, help='Input directory with audio files')
    parser.add_argument('--output', required=True, help='Output directory for .json files')
    parser.add_argument('--model', default='small.en', help='Whisper model name (default: small.en)')
    args = parser.parse_args()

    input_dir = Path(args.input)
    output_dir = Path(args.output)

    # Ensure output directory exists
    output_dir.mkdir(parents=True, exist_ok=True)

    # Find all audio files (support multiple formats including video files with audio tracks)
    audio_extensions = ['*.webm', '*.aac', '*.m4a', '*.mp3', '*.wav', '*.ogg', '*.flac', '*.mp4', '*.mov', '*.m4v', '*.avi']
    audio_files = []
    for ext in audio_extensions:
        audio_files.extend(input_dir.glob(ext))

    if not audio_files:
        print(f"ERROR: No audio files found in {input_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(audio_files)} audio files to transcribe", file=sys.stderr)

    # Load model ONCE (this is the key optimization)
    print(f"Loading Whisper model '{args.model}'...", file=sys.stderr)
    model_load_start = time.time()

    model = WhisperModel(
        args.model,
        device="cuda",
        compute_type="float16"
    )

    model_load_time = time.time() - model_load_start
    print(f"Model loaded in {model_load_time:.1f}s", file=sys.stderr)

    # Process all files
    batch_start = time.time()
    successful = 0
    failed = 0
    total_segments = 0

    for i, audio_path in enumerate(audio_files, 1):
        filename = audio_path.name
        output_filename = f"transcription-{audio_path.stem}.json"
        output_path = output_dir / output_filename

        print(f"[{i}/{len(audio_files)}] Processing {filename}...", file=sys.stderr)

        success, elapsed, num_segments = transcribe_file(model, str(audio_path), str(output_path))

        if success:
            successful += 1
            total_segments += num_segments
            print(f"  ✓ Done in {elapsed:.1f}s ({num_segments} segments)", file=sys.stderr)
        else:
            failed += 1
            print(f"  ✗ Failed", file=sys.stderr)

    # Summary
    batch_elapsed = time.time() - batch_start
    total_time = time.time() - model_load_start

    print("", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print("BATCH TRANSCRIPTION COMPLETE", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(f"Files processed:      {successful}/{len(audio_files)}", file=sys.stderr)
    print(f"Failed:               {failed}", file=sys.stderr)
    print(f"Total segments:       {total_segments}", file=sys.stderr)
    print(f"Model load time:      {model_load_time:.1f}s", file=sys.stderr)
    print(f"Transcription time:   {batch_elapsed:.1f}s", file=sys.stderr)
    print(f"Total time:           {total_time:.1f}s", file=sys.stderr)

    if successful > 0:
        avg_per_file = batch_elapsed / successful
        print(f"Average per file:     {avg_per_file:.1f}s (after model load)", file=sys.stderr)
        print(f"Speedup vs 1-at-time: ~{(model_load_time + avg_per_file * successful) / total_time:.1f}x", file=sys.stderr)

    print("=" * 60, file=sys.stderr)

    # Always exit 0 to allow orchestrator to handle partial success
    # Orchestrator will parse output summary to determine actual success/failure counts
    sys.exit(0)


if __name__ == "__main__":
    main()
