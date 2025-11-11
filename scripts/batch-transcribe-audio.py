#!/usr/bin/env python3
"""
Batch Transcribe Audio Files

This script transcribes audio files using faster-whisper with the same settings
as WhisperLive to ensure consistency between live and batch transcriptions.

Usage:
    python3 batch-transcribe-audio.py <audio_file_path>

Output:
    JSON object with segments and word-level timestamps
"""

import sys
import json
import os
from pathlib import Path

def transcribe_audio_file(audio_path, model_name="small.en"):
    """
    Transcribe audio file and return segments with word timestamps

    Args:
        audio_path: Path to audio file (.webm, .wav, .mp3, etc.)
        model_name: Whisper model to use (default: small.en to match WhisperLive)

    Returns:
        dict: {
            "segments": [
                {
                    "text": "transcribed text",
                    "start": 0.0,
                    "end": 5.2,
                    "is_final": true,
                    "words": [
                        {"word": "transcribed", "start": 0.0, "end": 0.5, "probability": 0.95},
                        ...
                    ]
                },
                ...
            ]
        }
    """
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print(json.dumps({
            "error": "faster-whisper not installed",
            "message": "Run: pip install faster-whisper"
        }), file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(audio_path):
        print(json.dumps({
            "error": "File not found",
            "path": audio_path
        }), file=sys.stderr)
        sys.exit(1)

    # Initialize model (matches WhisperLive configuration)
    # Use GPU if available, otherwise fall back to CPU
    try:
        model = WhisperModel(model_name, device="cuda", compute_type="float16")
    except:
        # Fallback to CPU if CUDA not available
        model = WhisperModel(model_name, device="cpu", compute_type="int8")

    # Transcribe with word timestamps (CRITICAL: must match WhisperLive)
    segments_iterator, info = model.transcribe(
        audio_path,
        beam_size=5,              # Match WhisperLive beam size
        word_timestamps=True,     # Enable word-level timestamps
        vad_filter=True,          # Voice activity detection
        vad_parameters=dict(
            min_silence_duration_ms=500
        )
    )

    # Convert iterator to list and format output
    result = []
    for segment in segments_iterator:
        seg_data = {
            "text": segment.text,
            "start": segment.start,
            "end": segment.end,
            "is_final": True,  # Batch transcriptions are always final
            "words": []
        }

        # Add word-level timestamps
        if segment.words:
            for word in segment.words:
                seg_data["words"].append({
                    "word": word.word,
                    "start": word.start,
                    "end": word.end,
                    "probability": word.probability
                })

        result.append(seg_data)

    return {
        "segments": result,
        "language": info.language,
        "language_probability": info.language_probability,
        "duration": info.duration
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 batch-transcribe-audio.py <audio_file_path>", file=sys.stderr)
        print("", file=sys.stderr)
        print("Example:", file=sys.stderr)
        print("  python3 batch-transcribe-audio.py /tmp/chunk-005.webm", file=sys.stderr)
        sys.exit(1)

    audio_file = sys.argv[1]

    try:
        result = transcribe_audio_file(audio_file)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({
            "error": str(e),
            "type": type(e).__name__
        }), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
