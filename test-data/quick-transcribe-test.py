#!/usr/bin/env python3
import asyncio
import websockets
import json
import sys

async def test():
    ws_url = f"ws://{sys.argv[1]}:9090"
    audio_file = sys.argv[2]

    try:
        async with websockets.connect(ws_url) as ws:
            # Send config
            await ws.send(json.dumps({
                'uid': 'startup-verify',
                'task': 'transcribe',
                'language': 'en',
                'model': 'small.en',
                'use_vad': False
            }))

            # Wait for SERVER_READY
            await asyncio.wait_for(ws.recv(), timeout=10.0)

            # Send audio
            with open(audio_file, 'rb') as f:
                audio = f.read()
            chunk_size = 16384
            for i in range(0, len(audio), chunk_size):
                await ws.send(audio[i:i+chunk_size])

            # Wait for transcription (up to 30s)
            for _ in range(15):
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                    data = json.loads(msg)
                    if data.get('segments'):
                        print("SUCCESS")
                        return True
                except asyncio.TimeoutError:
                    continue

            print("NO_TRANSCRIPTION")
            return False
    except Exception as e:
        print(f"ERROR: {e}")
        return False

if __name__ == "__main__":
    result = asyncio.run(test())
    sys.exit(0 if result else 1)
