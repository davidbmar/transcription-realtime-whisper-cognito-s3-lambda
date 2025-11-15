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
                "use_vad": False
            }
            await websocket.send(json.dumps(config))
            print(f"📤 Sent config: {config}")

            # Wait for SERVER_READY response
            print("⏳ Waiting for SERVER_READY...")
            try:
                server_ready = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                print(f"✅ Server ready: {server_ready}")
            except asyncio.TimeoutError:
                print("⚠️  No SERVER_READY received (continuing anyway)")

            # Read Float32 PCM audio file
            print(f"📂 Reading audio file: {audio_file}")
            print(f"🎵 Audio format: Float32 PCM @ 16kHz mono")

            # Read PCM file (Float32 Little Endian)
            with open(audio_file, 'rb') as f:
                audio_bytes = f.read()

            # Send all audio chunks first (don't wait for responses during sending)
            chunk_size = 16384  # bytes (match script 325)
            chunks_sent = 0

            for i in range(0, len(audio_bytes), chunk_size):
                chunk = audio_bytes[i:i + chunk_size]
                if not chunk:
                    break

                chunks_sent += 1
                await websocket.send(chunk)

            print(f"📤 Sent {chunks_sent} audio chunks")

            # Now wait for transcription responses (WhisperLive needs time to process)
            print("⏳ Waiting for transcription results...")
            all_transcripts = []
            messages_received = 0

            # Try for up to 60 seconds (30 attempts x 2s timeout)
            # WhisperLive needs time to process audio when VAD is disabled
            for attempt in range(30):
                try:
                    response = await asyncio.wait_for(websocket.recv(), timeout=2.0)
                    messages_received += 1

                    try:
                        data = json.loads(response)
                        print(f"📨 Received message {messages_received}: {data}")

                        # WhisperLive sends segments with transcription text
                        if 'segments' in data:
                            for seg in data['segments']:
                                text = seg.get('text', '').strip()
                                if text and text not in all_transcripts:
                                    print(f"📝 Transcription: {text}")
                                    all_transcripts.append(text)
                        elif 'text' in data:
                            text = data['text'].strip()
                            if text and text not in all_transcripts:
                                print(f"📝 Transcription: {text}")
                                all_transcripts.append(text)
                    except json.JSONDecodeError:
                        print(f"📨 Non-JSON message: {response[:100]}")

                except asyncio.TimeoutError:
                    if attempt < 29:  # Don't print on last attempt
                        print(f"  ⏱️  Waiting... ({attempt+1}/30)")
                    continue

            # Output results
            full_transcript = ' '.join(all_transcripts)
            print("\n" + "="*60)
            print("📄 FULL TRANSCRIPT:")
            print("="*60)
            print(full_transcript if full_transcript else "[No transcription received]")
            print("="*60)

            # Save to file
            output_file = Path(audio_file).parent / f"transcript-{session_id}.txt"
            output_file.write_text(full_transcript)
            print(f"\n✅ Saved transcript to: {output_file}")

            print(f"\n{'✅' if all_transcripts else '⚠️ '} Received {messages_received} messages, transcription={'YES' if all_transcripts else 'NO'}")

            # Return success if we received ANY messages (connection working)
            return full_transcript if messages_received > 0 else None

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
