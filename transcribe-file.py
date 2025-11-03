#!/usr/bin/env python3
"""
Transcribe audio files using WhisperLive server
Enables Claude to "hear" audio content
"""
import asyncio
import websockets
import json
import sys
import wave
import subprocess
import os
import time
from dotenv import load_dotenv, set_key, find_dotenv

# Load environment variables
load_dotenv()

WHISPERLIVE_HOST = os.getenv('WHISPERLIVE_HOST')
WHISPERLIVE_PORT = int(os.getenv('WHISPERLIVE_PORT', '9090'))

# Auto-update .env if WHISPERLIVE_HOST is missing but GPU_HOST exists
if not WHISPERLIVE_HOST:
    GPU_HOST = os.getenv('GPU_HOST')
    if GPU_HOST:
        print(f"WHISPERLIVE_HOST not set, using GPU_HOST: {GPU_HOST}")
        WHISPERLIVE_HOST = GPU_HOST
        # Update .env file
        env_file = find_dotenv()
        if env_file:
            set_key(env_file, 'WHISPERLIVE_HOST', GPU_HOST)
            print(f"Updated .env: WHISPERLIVE_HOST={GPU_HOST}")
        if not os.getenv('WHISPERLIVE_PORT'):
            set_key(env_file, 'WHISPERLIVE_PORT', '9090')
            print(f"Updated .env: WHISPERLIVE_PORT=9090")
    else:
        print("ERROR: WHISPERLIVE_HOST not set in .env file")
        print("Copy .env.example to .env and fill in your deployment values")
        sys.exit(1)

async def wait_for_server_ready(max_wait_seconds=120):
    """Wait for WhisperLive server to be ready by checking WebSocket connectivity"""
    uri = f"ws://{WHISPERLIVE_HOST}:{WHISPERLIVE_PORT}"
    start_time = time.time()
    attempt = 0

    print(f"Waiting for WhisperLive server at {uri} to be ready...")
    print(f"This may take up to {max_wait_seconds}s for model loading on first startup...")

    while time.time() - start_time < max_wait_seconds:
        attempt += 1
        try:
            # Try to connect with a quick timeout
            async with asyncio.timeout(5):
                async with websockets.connect(uri) as websocket:
                    # Send a test config
                    config = {
                        "uid": f"health-check-{os.getpid()}",
                        "task": "transcribe",
                        "language": "en",
                        "use_vad": False,
                    }
                    await websocket.send(json.dumps(config))

                    # Wait for any response (model loading confirmation)
                    try:
                        async with asyncio.timeout(10):
                            message = await websocket.recv()
                            # If we get here, server is responding
                            print(f"\n✓ Server ready after {int(time.time() - start_time)}s")
                            await websocket.close()
                            return True
                    except asyncio.TimeoutError:
                        # Server connected but slow to respond, it's still loading
                        pass
        except (ConnectionRefusedError, OSError, asyncio.TimeoutError, websockets.exceptions.WebSocketException):
            # Server not ready yet
            pass

        elapsed = int(time.time() - start_time)
        print(f"  Attempt {attempt} ({elapsed}/{max_wait_seconds}s)...", end='\r')
        await asyncio.sleep(5)

    print(f"\n✗ Server not ready after {max_wait_seconds}s")
    return False

async def transcribe_file(audio_file):
    """Send audio file to WhisperLive and get transcription"""
    
    # Convert webm to wav if needed
    if audio_file.endswith('.webm'):
        wav_file = audio_file.replace('.webm', '.wav')
        print(f"Converting {audio_file} to WAV format...")
        result = subprocess.run([
            'ffmpeg', '-i', audio_file, 
            '-ar', '16000',  # 16kHz sample rate
            '-ac', '1',       # Mono
            '-y',             # Overwrite
            wav_file
        ], capture_output=True, text=True)
        
        if result.returncode != 0:
            print(f"Error converting: {result.stderr}")
            return None
        audio_file = wav_file
    
    uri = f"ws://{WHISPERLIVE_HOST}:{WHISPERLIVE_PORT}"
    print(f"Connecting to WhisperLive at {uri}...")
    
    try:
        async with websockets.connect(uri) as websocket:
            # Send configuration
            config = {
                "uid": f"file-transcribe-{os.getpid()}",
                "task": "transcribe",
                "language": "en",
                "use_vad": False,  # Process entire file
            }
            await websocket.send(json.dumps(config))
            print("Sent configuration")
            
            # Read and send audio file
            with wave.open(audio_file, 'rb') as wf:
                chunk_size = 8192
                print(f"Sending audio data from {audio_file}...")
                
                while True:
                    data = wf.readframes(chunk_size)
                    if not data:
                        break
                    await websocket.send(data)
                
                # Send empty bytes to signal end
                await websocket.send(b'')
                print("Audio sent, waiting for transcription...")
            
            # Collect transcription with timeout
            transcription_parts = []
            timeout_seconds = 30  # 30 second timeout for receiving messages

            try:
                async with asyncio.timeout(timeout_seconds):
                    async for message in websocket:
                        try:
                            data = json.loads(message)

                            if 'segments' in data:
                                for segment in data['segments']:
                                    text = segment.get('text', '').strip()
                                    if text:
                                        transcription_parts.append(text)
                                        print(f"  > {text}")

                            # Check if transcription is complete
                            if data.get('message') == 'DISCONNECT' or not data:
                                break

                        except json.JSONDecodeError:
                            continue
            except asyncio.TimeoutError:
                if transcription_parts:
                    print(f"\nTimeout after {timeout_seconds}s, but received partial transcription")
                else:
                    print(f"\nTimeout after {timeout_seconds}s with no transcription")
                    print("This may indicate the WhisperLive server is still loading the model")
                    print("Try running the test again in 30-60 seconds")

            full_transcription = ' '.join(transcription_parts)
            return full_transcription if transcription_parts else None
            
    except Exception as e:
        print(f"Error: {e}")
        return None

async def main():
    if len(sys.argv) < 2:
        print("Usage: transcribe-file.py <audio_file>")
        sys.exit(1)

    audio_file = sys.argv[1]

    if not os.path.exists(audio_file):
        print(f"File not found: {audio_file}")
        sys.exit(1)

    print(f"\n{'='*60}")
    print(f"Transcribing: {audio_file}")
    print(f"{'='*60}\n")

    # Wait for server to be ready (important after fresh GPU startup)
    if not await wait_for_server_ready():
        print("\nERROR: WhisperLive server not responding")
        print("Check that the GPU instance is running and WhisperLive service is active")
        sys.exit(1)

    print("")  # Add spacing after readiness check
    transcription = await transcribe_file(audio_file)
    
    if transcription:
        print(f"\n{'='*60}")
        print("FULL TRANSCRIPTION:")
        print(f"{'='*60}")
        print(transcription)
        print(f"{'='*60}\n")
    else:
        print("No transcription received")

if __name__ == "__main__":
    asyncio.run(main())
