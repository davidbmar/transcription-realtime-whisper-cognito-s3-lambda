#!/usr/bin/env python3
"""
Script 524: Topic Segmentation for Transcripts

Analyzes transcripts using semantic embeddings to detect topic changes.
Works at the SENTENCE level (not paragraph/chunk level) for accurate detection.

How it works:
1. Extracts all words from transcript (preserving timestamps)
2. Groups words into sentences using punctuation and pauses
3. Generates embeddings for each sentence via Amazon Bedrock
4. Computes cosine similarity between consecutive sentences
5. Detects topic boundaries where similarity drops below threshold
6. Creates new paragraphs at topic boundaries

Uses:
- Amazon Bedrock (Titan Text Embeddings V2) for generating embeddings
- Amazon S3 Vectors for caching/storing embeddings (optional)

Usage:
    python 524-segment-transcripts-by-topic.py --session <s3-path>
    python 524-segment-transcripts-by-topic.py --input-path <file> --output-path <file>
    python 524-segment-transcripts-by-topic.py --session <path> --dry-run
    python 524-segment-transcripts-by-topic.py --session <path> --skip-cache

Arguments:
    --session         S3 session folder path (e.g., users/123/audio/sessions/abc)
    --input-path      Local input file path (alternative to --session)
    --output-path     Local output file path (optional, defaults to input folder)
    --mode            Input format: 'json' (default) or 'plain'
    --topic-threshold Similarity threshold (default from .env or 0.75)
    --dry-run         Show results without uploading
    --skip-cache      Force regenerate embeddings (don't use S3 Vectors cache)

Requirements:
    - boto3 (AWS SDK)
    - python-dotenv
    - Amazon Bedrock access (for embeddings)
    - Amazon S3 Vectors bucket (for caching, optional)
    - .env with COGNITO_S3_BUCKET, AWS_REGION, TOPIC_SIMILARITY_THRESHOLD

Performance:
    - ~2-5 seconds per 10 sentences (Bedrock API calls)
    - Cache hits are instant (S3 Vectors lookup)
    - Typical 20-min transcript: ~100 sentences, 20-50 seconds first run

Cost:
    - Titan Text Embeddings V2: ~$0.00002 per 1,000 tokens
    - Typical transcript: ~$0.001-0.002 (10,000-20,000 tokens)
"""

import argparse
import hashlib
import json
import math
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Tuple, Optional, Dict, Any

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    print("Error: boto3 is required. Install with: pip install boto3")
    sys.exit(1)

try:
    from dotenv import load_dotenv
except ImportError:
    print("Error: python-dotenv is required. Install with: pip install python-dotenv")
    sys.exit(1)

# Load environment from project root
PROJECT_ROOT = Path(__file__).parent.parent
load_dotenv(PROJECT_ROOT / '.env')

# ============================================================================
# Configuration
# ============================================================================

AWS_REGION = os.getenv('AWS_REGION', 'us-east-2')
S3_BUCKET = os.getenv('COGNITO_S3_BUCKET')
# Default threshold for sentence-level analysis with windowing
# Lower values = fewer topic breaks (only major shifts detected)
# Higher values = more topic breaks (more sensitive)
# Recommended: 0.20 for natural topic detection in conversational audio
TOPIC_THRESHOLD = float(os.getenv('TOPIC_SIMILARITY_THRESHOLD', '0.20'))
EMBEDDING_MODEL = os.getenv('EMBEDDING_MODEL_ID', 'amazon.titan-embed-text-v2:0')
EMBEDDING_DIMS = int(os.getenv('EMBEDDING_DIMENSIONS', '1024'))
S3_VECTORS_BUCKET = os.getenv('S3_VECTORS_BUCKET', 'clouddrive-embeddings')
S3_VECTORS_INDEX = os.getenv('S3_VECTORS_INDEX', 'transcript-segments')

# Initialize AWS clients lazily
_s3_client = None
_bedrock_client = None
_s3vectors_client = None


def get_s3_client():
    """Get or create S3 client."""
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client('s3', region_name=AWS_REGION)
    return _s3_client


def get_bedrock_client():
    """Get or create Bedrock Runtime client."""
    global _bedrock_client
    if _bedrock_client is None:
        _bedrock_client = boto3.client('bedrock-runtime', region_name=AWS_REGION)
    return _bedrock_client


def get_s3vectors_client():
    """
    Get or create S3 Vectors client.

    NOTE: S3 Vectors is in AWS Preview (July 2025) and may not be available
    in your boto3/botocore version. The script will work without it -
    embeddings will just be regenerated each time instead of cached.
    """
    global _s3vectors_client
    if _s3vectors_client is None:
        try:
            # Check if s3vectors is available in this boto3 version
            import botocore.exceptions
            _s3vectors_client = boto3.client('s3vectors', region_name=AWS_REGION)
        except botocore.exceptions.UnknownServiceError:
            # S3 Vectors not available in this SDK version - this is expected
            # until AWS releases it in standard SDK
            _s3vectors_client = False  # Mark as unavailable (silently)
        except Exception as e:
            print(f"  Note: S3 Vectors cache not available: {e}")
            _s3vectors_client = False  # Mark as unavailable
    return _s3vectors_client if _s3vectors_client else None


# ============================================================================
# S3 Vectors Cache Functions
# ============================================================================

def get_segment_key(text: str) -> str:
    """
    Generate a unique key for a text segment using MD5 hash.

    This allows caching embeddings by content, so identical text across
    different sessions will reuse the same embedding.
    """
    return hashlib.md5(text.encode('utf-8')).hexdigest()


def get_cached_embedding(segment_key: str) -> Optional[List[float]]:
    """
    Try to retrieve a cached embedding from S3 Vectors.

    Returns None if not found or if S3 Vectors is unavailable.
    """
    client = get_s3vectors_client()
    if client is None:
        return None

    try:
        response = client.get_vectors(
            vectorBucketName=S3_VECTORS_BUCKET,
            indexName=S3_VECTORS_INDEX,
            keys=[segment_key],
            returnData=True
        )
        vectors = response.get('vectors', [])
        if vectors and 'data' in vectors[0]:
            return vectors[0]['data'].get('float32', [])
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', '')
        if error_code not in ['NoSuchKey', 'ResourceNotFoundException']:
            print(f"  Warning: S3 Vectors cache lookup failed: {e}")
    except Exception as e:
        # Cache miss or error - will regenerate
        pass
    return None


def store_embedding_in_cache(
    segment_key: str,
    embedding: List[float],
    metadata: Dict[str, str]
) -> bool:
    """
    Store an embedding in S3 Vectors for future reuse.

    Returns True if successful, False otherwise.
    """
    client = get_s3vectors_client()
    if client is None:
        return False

    try:
        client.put_vectors(
            vectorBucketName=S3_VECTORS_BUCKET,
            indexName=S3_VECTORS_INDEX,
            vectors=[{
                'key': segment_key,
                'data': {'float32': embedding},
                'metadata': metadata
            }]
        )
        return True
    except Exception as e:
        print(f"  Warning: Failed to cache embedding: {e}")
        return False


# ============================================================================
# Embedding Functions
# ============================================================================

def get_embedding_from_bedrock(text: str) -> List[float]:
    """
    Get embedding for a single text string using Amazon Bedrock.

    Uses Titan Text Embeddings V2 by default.

    NOTE: To swap embedding models, modify EMBEDDING_MODEL in .env and adjust
    the request body format as needed for the target model.

    Args:
        text: The text to embed

    Returns:
        List of floats representing the embedding vector
    """
    client = get_bedrock_client()

    # Truncate text if too long (Titan has 8,192 token limit)
    # Approximate: 4 chars per token
    max_chars = 32000
    if len(text) > max_chars:
        text = text[:max_chars]

    request_body = {
        'inputText': text,
        'dimensions': EMBEDDING_DIMS,
        'normalize': True
    }

    try:
        response = client.invoke_model(
            modelId=EMBEDDING_MODEL,
            body=json.dumps(request_body),
            contentType='application/json',
            accept='application/json'
        )
        result = json.loads(response['body'].read())
        return result['embedding']
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', '')
        if error_code == 'AccessDeniedException':
            print(f"  Error: No access to Bedrock model {EMBEDDING_MODEL}")
            print(f"  Make sure the model is enabled in your AWS account")
            raise
        raise


def get_embeddings_for_segments(
    segments: List[str],
    session_id: str = '',
    use_cache: bool = True
) -> List[List[float]]:
    """
    Generate embeddings for a list of text segments.

    - Checks S3 Vectors cache first (if use_cache=True and available)
    - Generates new embeddings via Bedrock for cache misses
    - Stores new embeddings in S3 Vectors for future reuse

    Args:
        segments: List of text strings to embed
        session_id: Optional session ID for metadata
        use_cache: Whether to use S3 Vectors cache

    Returns:
        List of embedding vectors (same order as input segments)
    """
    embeddings = []
    cache_hits = 0
    cache_misses = 0

    total = len(segments)

    # Check if S3 Vectors cache is available
    cache_available = use_cache and get_s3vectors_client() is not None

    for i, segment in enumerate(segments):
        # Handle empty segments
        if not segment or not segment.strip():
            embeddings.append([0.0] * EMBEDDING_DIMS)
            continue

        segment_key = get_segment_key(segment)
        embedding = None

        # Try cache first (if available)
        if cache_available:
            embedding = get_cached_embedding(segment_key)
            if embedding:
                cache_hits += 1

        # Generate if not in cache
        if embedding is None:
            cache_misses += 1
            embedding = get_embedding_from_bedrock(segment)

            # Store in cache for future use (if available)
            if cache_available:
                store_embedding_in_cache(
                    segment_key,
                    embedding,
                    {
                        'session_id': session_id,
                        'segment_index': str(i),
                        'text_preview': segment[:100],
                        'created_at': datetime.now(timezone.utc).isoformat()
                    }
                )

        embeddings.append(embedding)

        # Progress update every 10 segments
        if (i + 1) % 10 == 0 or i + 1 == total:
            if cache_available:
                print(f"  Embedded {i + 1}/{total} segments "
                      f"(cache: {cache_hits} hits, {cache_misses} misses)")
            else:
                print(f"  Embedded {i + 1}/{total} segments via Bedrock")

    if cache_available:
        print(f"  Final: {cache_hits} from cache, {cache_misses} generated via Bedrock")
    else:
        print(f"  Final: {total} segments embedded via Bedrock (no cache)")
    return embeddings


# ============================================================================
# Similarity and Topic Detection
# ============================================================================

def cosine_similarity(vec_a: List[float], vec_b: List[float]) -> float:
    """
    Compute cosine similarity between two vectors.

    cosine_sim = (A . B) / (||A|| * ||B||)

    Returns value between -1 and 1, where:
    - 1 = identical direction (same topic)
    - 0 = orthogonal (unrelated)
    - -1 = opposite direction (rarely seen in text embeddings)

    Args:
        vec_a: First embedding vector
        vec_b: Second embedding vector

    Returns:
        Cosine similarity score
    """
    if len(vec_a) != len(vec_b):
        raise ValueError(f"Vectors must have same length: {len(vec_a)} vs {len(vec_b)}")

    dot_product = sum(a * b for a, b in zip(vec_a, vec_b))
    norm_a = math.sqrt(sum(a * a for a in vec_a))
    norm_b = math.sqrt(sum(b * b for b in vec_b))

    if norm_a == 0 or norm_b == 0:
        return 0.0

    return dot_product / (norm_a * norm_b)


def average_embedding(embeddings: List[List[float]]) -> List[float]:
    """Compute the average of multiple embedding vectors."""
    if not embeddings:
        return []
    if len(embeddings) == 1:
        return embeddings[0]

    dims = len(embeddings[0])
    avg = [0.0] * dims
    for emb in embeddings:
        for i, v in enumerate(emb):
            avg[i] += v
    return [v / len(embeddings) for v in avg]


def detect_topic_boundaries(
    embeddings: List[List[float]],
    threshold: float
) -> Tuple[List[int], List[float]]:
    """
    Detect topic boundaries based on cosine similarity between consecutive segments.

    A topic boundary is detected when the similarity between segment i and i+1
    drops below the threshold. This indicates a significant change in topic.

    Args:
        embeddings: List of embedding vectors
        threshold: Similarity threshold (0.0 to 1.0)

    Returns:
        Tuple of:
        - boundaries: List of indices where new topics start
        - similarities: List of similarity scores between consecutive segments
    """
    boundaries = []
    similarities = []

    for i in range(len(embeddings) - 1):
        sim = cosine_similarity(embeddings[i], embeddings[i + 1])
        similarities.append(sim)

        if sim < threshold:
            # Topic change detected between segment i and i+1
            # So segment i+1 starts a new topic
            boundaries.append(i + 1)

    return boundaries, similarities


def detect_topic_boundaries_windowed(
    embeddings: List[List[float]],
    threshold: float,
    window_size: int = 3
) -> Tuple[List[int], List[float]]:
    """
    Detect topic boundaries using a sliding window approach.

    Instead of comparing adjacent sentences directly, we compare the average
    embedding of a window of sentences before and after each potential boundary.
    This produces more stable similarity scores and fewer false positives.

    The algorithm:
    1. For each potential boundary point i
    2. Compute average embedding of sentences [i-window_size:i] (before)
    3. Compute average embedding of sentences [i:i+window_size] (after)
    4. If similarity < threshold, mark as boundary

    Args:
        embeddings: List of embedding vectors
        threshold: Similarity threshold (0.0 to 1.0)
        window_size: Number of sentences to average on each side

    Returns:
        Tuple of:
        - boundaries: List of indices where new topics start
        - similarities: List of similarity scores at each point
    """
    if len(embeddings) < 2:
        return [], []

    boundaries = []
    similarities = []

    # For each potential boundary point
    for i in range(1, len(embeddings)):
        # Get window before (up to window_size sentences)
        start_before = max(0, i - window_size)
        before_window = embeddings[start_before:i]

        # Get window after (up to window_size sentences)
        end_after = min(len(embeddings), i + window_size)
        after_window = embeddings[i:end_after]

        # Compute average embeddings
        before_avg = average_embedding(before_window)
        after_avg = average_embedding(after_window)

        # Compute similarity between windows
        sim = cosine_similarity(before_avg, after_avg)
        similarities.append(sim)

        if sim < threshold:
            boundaries.append(i)

    return boundaries, similarities


# ============================================================================
# Sentence Extraction
# ============================================================================

def extract_all_words_from_transcript(data: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Extract all words from transcript, flattening paragraph structure.

    Each word has: word, start, end, (optional) confidence
    """
    all_words = []
    paragraphs = data.get('paragraphs', [])

    for para in paragraphs:
        words = para.get('words', [])
        for w in words:
            all_words.append({
                'word': w.get('word', ''),
                'start': w.get('start', 0),
                'end': w.get('end', 0),
                'confidence': w.get('confidence', 1.0)
            })

    return all_words


def group_words_into_sentences(
    words: List[Dict[str, Any]],
    pause_threshold: float = 1.5
) -> List[Dict[str, Any]]:
    """
    Group words into sentences based on punctuation and pauses.

    Sentence boundaries are detected by:
    1. Sentence-ending punctuation (. ! ?)
    2. Long pauses between words (> pause_threshold seconds)

    Returns list of sentences, each with:
    - text: The sentence text
    - words: List of word objects
    - start: Start time of first word
    - end: End time of last word
    """
    import re

    if not words:
        return []

    sentences = []
    current_sentence_words = []

    for i, word_obj in enumerate(words):
        word = word_obj.get('word', '')
        current_sentence_words.append(word_obj)

        # Check if this word ends a sentence
        is_sentence_end = False

        # Check for sentence-ending punctuation
        if re.search(r'[.!?]$', word):
            is_sentence_end = True

        # Check for long pause before next word
        if i < len(words) - 1:
            next_word = words[i + 1]
            pause = next_word.get('start', 0) - word_obj.get('end', 0)
            if pause > pause_threshold:
                is_sentence_end = True

        # Last word is always end of sentence
        if i == len(words) - 1:
            is_sentence_end = True

        if is_sentence_end and current_sentence_words:
            # Build sentence
            sentence_text = ' '.join(w.get('word', '') for w in current_sentence_words)
            sentences.append({
                'text': sentence_text,
                'words': current_sentence_words.copy(),
                'start': current_sentence_words[0].get('start', 0),
                'end': current_sentence_words[-1].get('end', 0),
                'wordCount': len(current_sentence_words)
            })
            current_sentence_words = []

    return sentences


def merge_short_sentences(
    sentences: List[Dict[str, Any]],
    min_words: int = 5
) -> List[Dict[str, Any]]:
    """
    Merge very short sentences with neighbors for better embedding quality.

    Short sentences (< min_words) don't provide enough context for good embeddings.
    Merge them with the previous or next sentence.
    """
    if len(sentences) <= 1:
        return sentences

    merged = []
    i = 0

    while i < len(sentences):
        current = sentences[i]

        # Check if this sentence is too short
        if current['wordCount'] < min_words:
            # Try to merge with previous sentence
            if merged:
                prev = merged[-1]
                prev['text'] = prev['text'] + ' ' + current['text']
                prev['words'].extend(current['words'])
                prev['end'] = current['end']
                prev['wordCount'] = len(prev['words'])
            # Or merge with next sentence
            elif i < len(sentences) - 1:
                next_sent = sentences[i + 1]
                next_sent['text'] = current['text'] + ' ' + next_sent['text']
                next_sent['words'] = current['words'] + next_sent['words']
                next_sent['start'] = current['start']
                next_sent['wordCount'] = len(next_sent['words'])
                # Skip current, next will be processed normally
            else:
                # Last sentence and can't merge - keep it
                merged.append(current)
        else:
            merged.append(current)

        i += 1

    return merged


def extract_sentences_from_transcript(
    data: Dict[str, Any],
    pause_threshold: float = 1.5,
    min_sentence_words: int = 5
) -> List[Dict[str, Any]]:
    """
    Main function to extract sentences from a processed transcript.

    1. Extracts all words from paragraphs
    2. Groups words into sentences by punctuation/pauses
    3. Merges short sentences for better embedding quality

    Returns list of sentence objects with text, words, start, end.
    """
    # Extract all words
    all_words = extract_all_words_from_transcript(data)

    if not all_words:
        # Fallback: no word-level data, use paragraph text
        paragraphs = data.get('paragraphs', [])
        sentences = []
        for para in paragraphs:
            text = para.get('text', '')
            if text:
                # Simple sentence split
                import re
                parts = re.split(r'(?<=[.!?])\s+', text)
                for part in parts:
                    if part.strip():
                        sentences.append({
                            'text': part.strip(),
                            'words': [],
                            'start': para.get('startTime', 0),
                            'end': para.get('endTime', 0),
                            'wordCount': len(part.split())
                        })
        return merge_short_sentences(sentences, min_sentence_words)

    # Group into sentences
    sentences = group_words_into_sentences(all_words, pause_threshold)

    # Merge short sentences
    sentences = merge_short_sentences(sentences, min_sentence_words)

    return sentences


# ============================================================================
# Transcript Processing (Legacy - for backward compatibility)
# ============================================================================

def extract_segments_from_json(data: Dict[str, Any]) -> List[str]:
    """
    Extract text segments from a processed transcript JSON.

    DEPRECATED: Use extract_sentences_from_transcript for sentence-level analysis.
    This function extracts at the paragraph level which is less accurate.
    """
    paragraphs = data.get('paragraphs', [])
    return [p.get('text', '') for p in paragraphs]


def extract_segments_from_plain(text: str) -> List[str]:
    """
    Extract segments from plain text by splitting on sentences.

    Uses simple heuristics to split on sentence boundaries.
    """
    import re

    # Split on sentence-ending punctuation followed by space
    sentences = re.split(r'(?<=[.!?])\s+', text.strip())

    # Filter out empty segments
    return [s.strip() for s in sentences if s.strip()]


def build_paragraphs_from_sentences(
    sentences: List[Dict[str, Any]],
    boundaries: List[int],
    similarities: List[float]
) -> List[Dict[str, Any]]:
    """
    Build new paragraphs from sentences, with breaks at topic boundaries.

    Each topic boundary starts a new paragraph. Consecutive sentences
    in the same topic are merged into a single paragraph.

    Args:
        sentences: List of sentence objects with text, words, start, end
        boundaries: List of sentence indices that start new topics
        similarities: List of similarity scores between consecutive sentences

    Returns:
        List of new paragraph objects
    """
    if not sentences:
        return []

    # Convert boundaries to a set for O(1) lookup
    boundary_set = set(boundaries)

    paragraphs = []
    current_para_sentences = []
    current_para_words = []
    para_index = 0

    for i, sentence in enumerate(sentences):
        # Check if this sentence starts a new topic (and not the first)
        if i in boundary_set and current_para_sentences:
            # Save current paragraph
            para_text = ' '.join(s['text'] for s in current_para_sentences)
            start_time = current_para_sentences[0]['start']
            end_time = current_para_sentences[-1]['end']
            paragraphs.append({
                'id': f'para-topic-{para_index}',
                'text': para_text,
                'words': current_para_words.copy(),
                'segments': [],  # Required by frontend
                'chunkIds': [f'topic-{para_index + 1}'],  # Required by frontend
                'start': start_time,
                'end': end_time,
                'duration': end_time - start_time,
                'wordCount': len(current_para_words),
                'isTopicStart': para_index == 0 or (para_index > 0),
                'topicSimilarity': similarities[i - 1] if i > 0 and i - 1 < len(similarities) else 1.0,
                'sentenceCount': len(current_para_sentences)
            })
            para_index += 1
            current_para_sentences = []
            current_para_words = []

        # Add sentence to current paragraph
        current_para_sentences.append(sentence)
        current_para_words.extend(sentence.get('words', []))

    # Don't forget the last paragraph
    if current_para_sentences:
        para_text = ' '.join(s['text'] for s in current_para_sentences)
        is_topic_start = len(paragraphs) == 0 or (len(sentences) - len(current_para_sentences)) in boundary_set
        start_time = current_para_sentences[0]['start']
        end_time = current_para_sentences[-1]['end']
        paragraphs.append({
            'id': f'para-topic-{para_index}',
            'text': para_text,
            'words': current_para_words.copy(),
            'segments': [],  # Required by frontend
            'chunkIds': [f'topic-{para_index + 1}'],  # Required by frontend
            'start': start_time,
            'end': end_time,
            'duration': end_time - start_time,
            'wordCount': len(current_para_words),
            'isTopicStart': is_topic_start if para_index > 0 else True,
            'topicSimilarity': 1.0,  # Last paragraph has no "next" to compare
            'sentenceCount': len(current_para_sentences)
        })

    # Mark topic starts correctly
    # First paragraph is always topic start
    if paragraphs:
        paragraphs[0]['isTopicStart'] = True

    return paragraphs


def format_transcript_with_topics(
    processed_data: Dict[str, Any],
    boundaries: List[int],
    similarities: List[float],
    threshold: float
) -> Dict[str, Any]:
    """
    Create new transcript structure with topic boundaries marked.

    DEPRECATED: Use format_transcript_with_sentence_topics for sentence-level.

    Modifies paragraphs to add:
    - isTopicStart: bool - True if this paragraph starts a new topic
    - topicSimilarity: float - Similarity to previous paragraph

    Args:
        processed_data: Original transcript data
        boundaries: List of topic boundary indices
        similarities: List of similarity scores
        threshold: Threshold used for detection

    Returns:
        Updated transcript data with topic information
    """
    paragraphs = processed_data.get('paragraphs', [])

    for i, para in enumerate(paragraphs):
        # First paragraph always starts a topic
        para['isTopicStart'] = i in boundaries or i == 0

        # Add similarity score to previous paragraph
        if i > 0 and i - 1 < len(similarities):
            para['topicSimilarity'] = round(similarities[i - 1], 4)
        else:
            para['topicSimilarity'] = 1.0

    # Count topics
    topic_count = sum(1 for p in paragraphs if p.get('isTopicStart', False))

    # Update metadata
    metadata = processed_data.get('metadata', {})
    metadata['topicSegmented'] = True
    metadata['topicSegmentedAt'] = datetime.now(timezone.utc).isoformat()
    metadata['topicCount'] = topic_count
    metadata['topicThreshold'] = threshold
    metadata['embeddingModel'] = EMBEDDING_MODEL
    metadata['embeddingDimensions'] = EMBEDDING_DIMS

    # Calculate average similarity for stats
    avg_similarity = sum(similarities) / len(similarities) if similarities else 1.0

    return {
        **processed_data,
        'paragraphs': paragraphs,
        'metadata': metadata,
        'topicBoundaries': boundaries,
        'topicStats': {
            'topicCount': topic_count,
            'averageSimilarity': round(avg_similarity, 4),
            'minSimilarity': round(min(similarities), 4) if similarities else 1.0,
            'maxSimilarity': round(max(similarities), 4) if similarities else 1.0,
            'threshold': threshold
        },
        'version': processed_data.get('version', '1.0') + '-topics'
    }


def format_transcript_with_sentence_topics(
    processed_data: Dict[str, Any],
    sentences: List[Dict[str, Any]],
    boundaries: List[int],
    similarities: List[float],
    threshold: float
) -> Dict[str, Any]:
    """
    Create new transcript with paragraphs rebuilt from sentence-level topic detection.

    This is the main output function that:
    1. Takes sentences with topic boundaries
    2. Builds new paragraphs (one per topic)
    3. Preserves word-level data for highlighting

    Args:
        processed_data: Original transcript data (for metadata)
        sentences: List of sentence objects
        boundaries: List of sentence indices that start new topics
        similarities: List of similarity scores between sentences
        threshold: Threshold used for detection

    Returns:
        New transcript structure with topic-based paragraphs
    """
    # Build new paragraphs from sentences
    new_paragraphs = build_paragraphs_from_sentences(sentences, boundaries, similarities)

    # Count topics
    topic_count = sum(1 for p in new_paragraphs if p.get('isTopicStart', False))

    # Update metadata
    metadata = processed_data.get('metadata', {}).copy()
    metadata['topicSegmented'] = True
    metadata['topicSegmentedAt'] = datetime.now(timezone.utc).isoformat()
    metadata['topicCount'] = topic_count
    metadata['topicThreshold'] = threshold
    metadata['embeddingModel'] = EMBEDDING_MODEL
    metadata['embeddingDimensions'] = EMBEDDING_DIMS
    metadata['segmentationMethod'] = 'sentence-level'
    metadata['sentenceCount'] = len(sentences)

    # Calculate similarity stats
    avg_similarity = sum(similarities) / len(similarities) if similarities else 1.0

    # Calculate total words and duration for stats
    total_words = sum(len(p.get('words', [])) for p in new_paragraphs)
    total_duration = 0
    if new_paragraphs:
        first_start = new_paragraphs[0].get('start', 0)
        last_end = new_paragraphs[-1].get('end', 0)
        total_duration = last_end - first_start

    # Calculate words per minute
    words_per_minute = (total_words / (total_duration / 60)) if total_duration > 0 else 0

    # Copy stats from original if available, otherwise compute
    original_stats = processed_data.get('stats', {})
    stats = {
        'paragraphCount': len(new_paragraphs),
        'totalWords': total_words or original_stats.get('totalWords', 0),
        'totalDuration': total_duration or original_stats.get('totalDuration', 0),
        'averageWordsPerParagraph': round(total_words / len(new_paragraphs), 2) if new_paragraphs else 0,
        'wordsPerMinute': round(words_per_minute, 2) if words_per_minute else original_stats.get('wordsPerMinute', 0)
    }

    return {
        'paragraphs': new_paragraphs,
        'stats': stats,
        'metadata': metadata,
        'topicBoundaries': boundaries,
        'topicStats': {
            'topicCount': topic_count,
            'sentenceCount': len(sentences),
            'paragraphCount': len(new_paragraphs),
            'averageSimilarity': round(avg_similarity, 4),
            'minSimilarity': round(min(similarities), 4) if similarities else 1.0,
            'maxSimilarity': round(max(similarities), 4) if similarities else 1.0,
            'threshold': threshold
        },
        'version': processed_data.get('version', '1.0') + '-sentence-topics'
    }


def format_plain_text_with_topics(
    segments: List[str],
    boundaries: List[int]
) -> str:
    """
    Format plain text with paragraph breaks at topic boundaries.

    Inserts double newlines (blank line) at topic boundaries,
    single newlines otherwise.
    """
    result = []

    for i, segment in enumerate(segments):
        if i in boundaries and i > 0:
            # Topic boundary - add blank line before
            result.append('\n\n')
        elif i > 0:
            # Same topic - just add space
            result.append(' ')

        result.append(segment)

    return ''.join(result)


# ============================================================================
# S3 Operations
# ============================================================================

def download_from_s3(session_folder: str, filename: str = 'transcription-processed.json') -> Dict[str, Any]:
    """Download and parse a JSON file from S3."""
    client = get_s3_client()

    key = f"{session_folder}/{filename}"
    print(f"  Downloading s3://{S3_BUCKET}/{key}")

    try:
        response = client.get_object(Bucket=S3_BUCKET, Key=key)
        content = response['Body'].read().decode('utf-8')
        return json.loads(content)
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', '')
        if error_code == 'NoSuchKey':
            raise FileNotFoundError(f"File not found: s3://{S3_BUCKET}/{key}")
        raise


def upload_to_s3(session_folder: str, data: Dict[str, Any], filename: str = 'transcription-topic-segmented.json') -> str:
    """Upload JSON data to S3.

    NEW LAYER ARCHITECTURE: Also writes to layers/layer-3-topic-segments/data.json
    """
    client = get_s3_client()
    content = json.dumps(data, indent=2)
    metadata = {
        'topic-count': str(data.get('topicStats', {}).get('topicCount', 0)),
        'topic-threshold': str(data.get('topicStats', {}).get('threshold', TOPIC_THRESHOLD)),
        'generated-by': 'script-524-topic-segmentation',
        'generated-at': datetime.now(timezone.utc).isoformat()
    }

    # NEW LAYER ARCHITECTURE: Upload to layers/layer-3-topic-segments/data.json
    layer_key = f"{session_folder}/layers/layer-3-topic-segments/data.json"
    print(f"  Uploading to s3://{S3_BUCKET}/{layer_key}")
    client.put_object(
        Bucket=S3_BUCKET,
        Key=layer_key,
        Body=content.encode('utf-8'),
        ContentType='application/json',
        Metadata=metadata
    )

    # BACKWARDS COMPATIBILITY: Also upload to old location
    old_key = f"{session_folder}/{filename}"
    print(f"  Also uploading to s3://{S3_BUCKET}/{old_key} (backwards compat)")
    client.put_object(
        Bucket=S3_BUCKET,
        Key=old_key,
        Body=content.encode('utf-8'),
        ContentType='application/json',
        Metadata=metadata
    )

    return f"s3://{S3_BUCKET}/{layer_key}"


# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    """Main entry point for the script."""
    parser = argparse.ArgumentParser(
        description='Segment transcripts by topic using semantic embeddings',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Process a single session from S3
  python 524-segment-transcripts-by-topic.py --session users/123/audio/sessions/abc

  # Process with custom threshold (more topic breaks)
  python 524-segment-transcripts-by-topic.py --session users/123/audio/sessions/abc --topic-threshold 0.6

  # Dry run to see what would be detected
  python 524-segment-transcripts-by-topic.py --session users/123/audio/sessions/abc --dry-run

  # Process local file
  python 524-segment-transcripts-by-topic.py --input-path transcript.json --output-path output.json
        """
    )

    parser.add_argument(
        '--session',
        help='S3 session folder path (e.g., users/123/audio/sessions/abc)'
    )
    parser.add_argument(
        '--input-path',
        help='Local input file path (alternative to --session)'
    )
    parser.add_argument(
        '--output-path',
        help='Local output file path (optional)'
    )
    parser.add_argument(
        '--mode',
        choices=['json', 'plain'],
        default='json',
        help='Input format: json (default) or plain text'
    )
    parser.add_argument(
        '--topic-threshold',
        type=float,
        default=TOPIC_THRESHOLD,
        help=f'Similarity threshold for topic detection (default: {TOPIC_THRESHOLD})'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show results without uploading'
    )
    parser.add_argument(
        '--skip-cache',
        action='store_true',
        help='Force regenerate embeddings (skip S3 Vectors cache)'
    )
    parser.add_argument(
        '--force',
        action='store_true',
        help='Force re-run even if topic-segmented output already exists'
    )

    args = parser.parse_args()

    # Validate arguments
    if not args.session and not args.input_path:
        # Check if threshold is not set and prompt
        if not os.getenv('TOPIC_SIMILARITY_THRESHOLD'):
            print("TOPIC_SIMILARITY_THRESHOLD not set in .env")
            print(f"Using default threshold: {TOPIC_THRESHOLD}")
            print("")
            response = input(f"Enter threshold (0.0-1.0) or press Enter for default [{TOPIC_THRESHOLD}]: ").strip()
            if response:
                try:
                    args.topic_threshold = float(response)
                    if not 0.0 <= args.topic_threshold <= 1.0:
                        print("Error: Threshold must be between 0.0 and 1.0")
                        sys.exit(1)
                except ValueError:
                    print("Error: Invalid threshold value")
                    sys.exit(1)
            print("")

        parser.error('Either --session or --input-path is required')

    print("=" * 60)
    print("Script 524: Topic Segmentation")
    print("=" * 60)
    print("")
    print(f"Configuration:")
    print(f"  Topic threshold: {args.topic_threshold}")
    print(f"  Embedding model: {EMBEDDING_MODEL}")
    print(f"  Embedding dimensions: {EMBEDDING_DIMS}")
    print(f"  Use cache: {not args.skip_cache}")
    print(f"  Dry run: {args.dry_run}")
    print("")

    # Load transcript
    processed_data = None
    session_id = ''

    if args.session:
        # Strip s3://bucket/ prefix if present
        session_path = args.session
        if session_path.startswith('s3://'):
            # Remove s3://bucket/ prefix to get just the key path
            parts = session_path.replace('s3://', '').split('/', 1)
            if len(parts) > 1:
                session_path = parts[1]  # Everything after bucket name

        session_id = session_path.split('/')[-1] if '/' in session_path else session_path

        # Check if output already exists (skip unless --force)
        if not args.force and not args.dry_run:
            s3 = get_s3_client()
            output_key = f"{session_path}/transcription-topic-segmented.json"
            try:
                s3.head_object(Bucket=S3_BUCKET, Key=output_key)
                print(f"[SKIP] {session_path} - topic segmentation already exists")
                print(f"       Use --force to re-run")
                sys.exit(0)
            except ClientError:
                pass  # File doesn't exist, proceed with processing

        print(f"Loading transcript from S3...")
        print(f"  Session: {session_path}")

        try:
            processed_data = download_from_s3(session_path)
        except FileNotFoundError as e:
            print(f"Error: {e}")
            print("Make sure the session has been postprocessed (run script 518)")
            sys.exit(1)

    elif args.input_path:
        session_id = Path(args.input_path).stem
        print(f"Loading transcript from local file...")
        print(f"  Path: {args.input_path}")

        with open(args.input_path, 'r') as f:
            if args.mode == 'json':
                processed_data = json.load(f)
            else:
                text = f.read()
                # Create a simple structure for plain text
                segments = extract_segments_from_plain(text)
                processed_data = {
                    'paragraphs': [{'text': s, 'paragraphIndex': i} for i, s in enumerate(segments)],
                    'metadata': {'source': 'plain-text'}
                }

    print("")

    # ========================================================================
    # SENTENCE-LEVEL TOPIC DETECTION
    # ========================================================================
    # Extract sentences from words (not paragraphs) for accurate topic detection
    # This works regardless of chunk/paragraph boundaries from recording

    print("Extracting sentences from transcript...")
    sentences = extract_sentences_from_transcript(processed_data)

    print(f"  Extracted {len(sentences)} sentences from transcript")

    if len(sentences) < 2:
        print("")
        print("Warning: Need at least 2 sentences for topic detection")
        print("Skipping topic segmentation")
        sys.exit(0)

    # Show sentence stats
    total_words = sum(s.get('wordCount', 0) for s in sentences)
    avg_words = total_words / len(sentences) if sentences else 0
    print(f"  Total words: {total_words}")
    print(f"  Average words per sentence: {avg_words:.1f}")
    print("")

    # Generate embeddings for each sentence
    print("Generating embeddings for sentences...")
    sentence_texts = [s['text'] for s in sentences]

    try:
        embeddings = get_embeddings_for_segments(
            sentence_texts,
            session_id=session_id,
            use_cache=not args.skip_cache
        )
    except ClientError as e:
        print(f"\nError: Failed to generate embeddings: {e}")
        sys.exit(1)

    print("")

    # Detect topic boundaries between sentences using windowed approach
    # Window size of 3 means we compare average of 3 sentences before/after each point
    window_size = 3
    print(f"Detecting topic boundaries (threshold: {args.topic_threshold}, window: {window_size})...")
    boundaries, similarities = detect_topic_boundaries_windowed(embeddings, args.topic_threshold, window_size)

    topic_count = len(boundaries) + 1  # +1 for the first implicit topic
    print(f"  Detected {topic_count} topics ({len(boundaries)} boundaries)")
    print("")

    # Show similarity stats
    if similarities:
        avg_sim = sum(similarities) / len(similarities)
        min_sim = min(similarities)
        max_sim = max(similarities)
        print(f"Similarity statistics:")
        print(f"  Average: {avg_sim:.4f}")
        print(f"  Min: {min_sim:.4f}")
        print(f"  Max: {max_sim:.4f}")
        print("")

        # Show where boundaries are (sentences that start new topics)
        if boundaries:
            print("Topic boundaries at sentences:")
            for b in boundaries[:10]:  # Show first 10
                if b < len(sentences):
                    preview = sentences[b]['text'][:60] + "..." if len(sentences[b]['text']) > 60 else sentences[b]['text']
                    sim = similarities[b - 1] if b - 1 < len(similarities) else 0
                    time_str = f"{sentences[b]['start']:.1f}s"
                    print(f"  [{b}] @{time_str} (sim={sim:.3f}): {preview}")
            if len(boundaries) > 10:
                print(f"  ... and {len(boundaries) - 10} more")
            print("")

    # Format output using sentence-level topic detection
    output_data = format_transcript_with_sentence_topics(
        processed_data,
        sentences,
        boundaries,
        similarities,
        args.topic_threshold
    )

    # Save output
    if args.dry_run:
        print("DRY RUN - Not saving output")
        print("")
        print("Output preview (metadata):")
        print(json.dumps(output_data.get('metadata', {}), indent=2))
        print("")
        print("Topic stats:")
        print(json.dumps(output_data.get('topicStats', {}), indent=2))
    else:
        if args.session:
            # Upload to S3 (use cleaned session_path)
            output_url = upload_to_s3(session_path, output_data)
            print("")
            print(f"Output saved to: {output_url}")
        elif args.output_path:
            # Save to local file
            with open(args.output_path, 'w') as f:
                json.dump(output_data, f, indent=2)
            print(f"Output saved to: {args.output_path}")
        else:
            # Default output path
            output_path = args.input_path.replace('.json', '-topics.json')
            with open(output_path, 'w') as f:
                json.dump(output_data, f, indent=2)
            print(f"Output saved to: {output_path}")

    print("")
    print("=" * 60)
    print("Topic segmentation complete!")
    print("=" * 60)
    print(f"  Sentences analyzed: {len(sentences)}")
    print(f"  Topics detected: {topic_count}")
    print(f"  New paragraphs: {len(output_data.get('paragraphs', []))}")
    print(f"  Threshold used: {args.topic_threshold}")


if __name__ == '__main__':
    main()
