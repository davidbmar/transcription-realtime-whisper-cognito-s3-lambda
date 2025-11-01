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
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

WHISPERLIVE_HOST = os.getenv('WHISPERLIVE_HOST')
WHISPERLIVE_PORT = int(os.getenv('WHISPERLIVE_PORT', '9090'))

if not WHISPERLIVE_HOST:
    print("ERROR: WHISPERLIVE_HOST not set in .env file")
    print("Copy .env.example to .env and fill in your deployment values")
    sys.exit(1)

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
            
            # Collect transcription
            transcription_parts = []
            
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
            
            full_transcription = ' '.join(transcription_parts)
            return full_transcription
            
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
