#!/usr/bin/env python3
"""
WebSocket Test Client for WhisperLive
Simulates browser audio recording pipeline
"""

import asyncio
import websockets
import wave
import json
import sys
import struct
from pathlib import Path

async def test_transcription(ws_url, audio_file, session_id):
    """Send audio file to WhisperLive and capture transcription"""

    print(f"🔌 Connecting to {ws_url}...")

    # Disable SSL verification for self-signed certificates
    import ssl
    ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    try:
        async with websockets.connect(ws_url, ssl=ssl_context) as websocket:
            print("✅ WebSocket connected")

            # Send initial config (same as browser client)
            config = {
                "uid": session_id,
                "language": "en",
                "task": "transcribe",
                "model": "small.en",
                "use_vad": True
            }
            await websocket.send(json.dumps(config))
            print(f"📤 Sent config: {config}")

            # Read audio file
            print(f"📂 Reading audio file: {audio_file}")
            with wave.open(str(audio_file), 'rb') as wf:
                sample_rate = wf.getframerate()
                channels = wf.getnchannels()
                sample_width = wf.getsampwidth()

                print(f"🎵 Audio: {sample_rate}Hz, {channels}ch, {sample_width*8}bit")

                if sample_rate != 16000 or channels != 1:
                    print("⚠️  Warning: Audio should be 16kHz mono for best results")

                # Send audio in chunks (simulate browser's MediaRecorder)
                chunk_size = 8192  # bytes
                chunk_num = 0
                all_transcripts = []

                while True:
                    audio_data = wf.readframes(chunk_size // (sample_width * channels))
                    if not audio_data:
                        break

                    chunk_num += 1
                    await websocket.send(audio_data)
                    print(f"📤 Sent chunk {chunk_num} ({len(audio_data)} bytes)")

                    # Try to receive transcription (non-blocking)
                    try:
                        response = await asyncio.wait_for(websocket.recv(), timeout=0.1)
                        transcript_data = json.loads(response)

                        if 'segments' in transcript_data:
                            for seg in transcript_data['segments']:
                                text = seg.get('text', '').strip()
                                if text:
                                    print(f"📝 Transcription: {text}")
                                    all_transcripts.append(text)
                    except asyncio.TimeoutError:
                        pass  # No response yet

                    # Small delay between chunks
                    await asyncio.sleep(0.1)

            # Send end-of-stream signal
            await websocket.send(json.dumps({"eof": 1}))
            print("🏁 Sent end-of-stream signal")

            # Wait for final transcription
            print("⏳ Waiting for final transcription...")
            try:
                final_response = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                final_data = json.loads(final_response)

                if 'segments' in final_data:
                    for seg in final_data['segments']:
                        text = seg.get('text', '').strip()
                        if text and text not in all_transcripts:
                            print(f"📝 Final transcription: {text}")
                            all_transcripts.append(text)
            except asyncio.TimeoutError:
                print("⏰ Timeout waiting for final transcription")

            # Output results
            full_transcript = ' '.join(all_transcripts)
            print("\n" + "="*60)
            print("📄 FULL TRANSCRIPT:")
            print("="*60)
            print(full_transcript)
            print("="*60)

            # Save to file
            output_file = Path(audio_file).parent / f"transcript-{session_id}.txt"
            output_file.write_text(full_transcript)
            print(f"\n✅ Saved transcript to: {output_file}")

            return full_transcript

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return None

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 websocket_test_client.py <ws_url> <audio_file> [session_id]")
        sys.exit(1)

    ws_url = sys.argv[1]
    audio_file = sys.argv[2]
    session_id = sys.argv[3] if len(sys.argv) > 3 else f"test-{int(asyncio.get_event_loop().time())}"

    result = asyncio.run(test_transcription(ws_url, audio_file, session_id))
    sys.exit(0 if result else 1)
