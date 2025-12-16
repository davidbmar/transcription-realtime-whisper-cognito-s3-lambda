# Learning Prompt: S3 Presigned URLs for Audio Transcription

Copy this prompt to use with an LLM to learn about presigned URLs and this architecture.

---

## PROMPT

I'm building an audio transcription system and just implemented S3 presigned URLs to solve a timeout problem. I want to fully understand how this works. Please teach me about presigned URLs and help me understand my implementation.

### My Problem (Before)

I have this architecture:
```
Edge Box ──[upload 142MB audio]──> Cloudflare Proxy ──> RunPod GPU
                                        │
                                   TIMEOUT (100s)
```

Large audio files (74+ minutes = 142MB) were timing out because:
1. Cloudflare proxy has ~100 second HTTP timeout
2. Uploading 142MB takes longer than 100s
3. Transcription takes 15+ minutes
4. Result: `error code: 524` (Cloudflare timeout)

### My Solution (After)

Now I use presigned URLs:
```
Edge Box                          RunPod GPU                    S3
    │                                 │                          │
    ├─ Generate presigned URLs        │                          │
    │                                 │                          │
    ├──[POST /transcribe]────────────►│                          │
    │  {audio_url, result_url}        │                          │
    │  (2KB JSON only!)               │                          │
    │                                 │                          │
    │                                 ├──[GET audio.wav]────────►│
    │                                 │  (142MB direct from S3)  │
    │                                 │                          │
    │                                 │  [TRANSCRIBE 15 min]     │
    │                                 │                          │
    │                                 ├──[PUT result.json]──────►│
    │                                 │  (3MB direct to S3)      │
    │                                 │                          │
    │◄──[{"status":"ok"}]────────────┤                          │
    │   (1KB response)                │                          │
```

### My Code

**Generating GET URL (bash):**
```bash
audio_url=$(aws s3 presign "s3://mybucket/path/audio.wav" --expires-in 7200)
```

**Generating PUT URL (python):**
```python
import boto3
s3 = boto3.client('s3')
url = s3.generate_presigned_url(
    'put_object',
    Params={
        'Bucket': 'mybucket',
        'Key': 'path/transcription.json',
        'ContentType': 'application/json'
    },
    ExpiresIn=7200
)
```

**RunPod downloading from presigned URL:**
```python
response = requests.get(audio_url, stream=True, timeout=600)
with open(audio_path, 'wb') as f:
    for chunk in response.iter_content(chunk_size=8192):
        f.write(chunk)
```

**RunPod uploading to presigned URL:**
```python
requests.put(
    result_url,
    data=json.dumps(result),
    headers={"Content-Type": "application/json"}
)
```

### What I Want to Understand

Please explain:

1. **How presigned URLs work technically**
   - What is the signature? How is it generated?
   - What information is embedded in the URL?
   - How does S3 verify the signature?

2. **Security model**
   - Why is this secure if the URL is passed to a third party (RunPod)?
   - What can an attacker do if they intercept the URL?
   - What are the risks and mitigations?

3. **GET vs PUT presigned URLs**
   - Why does `aws s3 presign` only generate GET URLs?
   - Why do I need boto3 for PUT URLs?
   - Are there other operations I can presign?

4. **Expiry and timing**
   - How does the expiry work? Is it checked on request start or throughout?
   - What happens if upload/download is in progress when URL expires?
   - What's a good expiry time for my use case (large file transfers + long processing)?

5. **IAM permissions**
   - What IAM permissions does the Edge Box need?
   - Does RunPod need any AWS permissions? (I think no)
   - Can I scope permissions to specific paths?

6. **Best practices**
   - Should I generate URLs with longer expiry for batch processing?
   - Should I regenerate URLs on retry?
   - Any gotchas with presigned URLs I should know?

7. **Alternatives**
   - Are there other solutions to my timeout problem?
   - When would presigned URLs NOT be the right solution?

### Bonus Questions

- What's AWS Signature Version 4 and how does it relate to presigned URLs?
- Can presigned URLs be revoked before expiry?
- How do presigned URLs interact with bucket policies and ACLs?
- Can I use presigned URLs with S3 Transfer Acceleration?

Please explain in a way that helps me truly understand, not just use, this technology.

---

## Context Files

If you want to share more context with the LLM, these files document the full implementation:

- `~/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/docs/PRESIGNED_URL_TRANSCRIPTION.md` - Architecture overview
- `~/event-b/whisperX-runpod/docs/PRESIGNED_URL_DESIGN.md` - Original design document
- `~/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/scripts/515-runpod--batch-transcribe.sh` - Batch script implementation
- `~/event-b/whisperX-runpod/src/handler_pod.py` - RunPod handler implementation
