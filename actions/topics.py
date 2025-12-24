"""
Topic Segmentation Action.

Segment transcript by topic using semantic embeddings.
Uses Amazon Bedrock Titan embeddings for similarity detection.

This wraps the existing scripts/524-segment-transcripts-by-topic.py functionality.
"""

import json
import math
import re
import logging
from datetime import datetime, timezone
from typing import Dict, List, Tuple

import boto3

from .base import ActionBase, ActionResult
from .config import AWS_REGION, EMBEDDING_MODEL, EMBEDDING_DIMS, TOPIC_THRESHOLD

logger = logging.getLogger(__name__)


class TopicsAction(ActionBase):
    """Detect topic boundaries using semantic embeddings."""

    name = 'topics'
    description = 'Detect topic boundaries using semantic embeddings'
    requires = ['transcription-processed.json']
    produces = ['layers/layer-3-topic-segments/data.json', 'transcription-topic-segmented.json']

    def __init__(self):
        super().__init__()
        self._bedrock = boto3.client('bedrock-runtime', region_name=AWS_REGION)

    def run(self, session_path: str, params: Dict) -> ActionResult:
        """
        Run topic segmentation on transcript.

        Args:
            session_path: S3 path like users/123/audio/sessions/abc
            params: Optional params:
                - threshold: float - Similarity threshold (default from .env)
                - window_size: int - Window size for averaging (default 3)
                - force: bool - Re-run even if output exists

        Returns:
            ActionResult with success status
        """
        threshold = params.get('threshold', TOPIC_THRESHOLD)
        window_size = params.get('window_size', 3)
        force = params.get('force', False)

        # Check if output already exists
        if not force and self.file_exists(session_path, 'layers/layer-3-topic-segments/data.json'):
            logger.info("Topic segmentation already exists. Use force=True to re-run.")
            return ActionResult(
                success=True,
                outputs=self.produces,
                duration_seconds=self.elapsed(),
                metadata={'skipped': True, 'reason': 'already exists'}
            )

        # Load transcript
        transcript = self.load_file(session_path, 'transcription-processed.json')

        # Extract sentences from transcript
        sentences = self._extract_sentences(transcript)
        logger.info(f"Extracted {len(sentences)} sentences from transcript")

        if len(sentences) < 2:
            return ActionResult(
                success=True,
                outputs=[],
                duration_seconds=self.elapsed(),
                metadata={'message': 'Not enough sentences for topic detection'}
            )

        # Generate embeddings for each sentence
        logger.info("Generating embeddings via Bedrock...")
        embeddings = self._get_embeddings([s['text'] for s in sentences])

        # Detect topic boundaries using windowed approach
        logger.info(f"Detecting topic boundaries (threshold={threshold}, window={window_size})...")
        boundaries, similarities = self._detect_boundaries_windowed(
            embeddings, threshold, window_size
        )

        topic_count = len(boundaries) + 1
        logger.info(f"Detected {topic_count} topics ({len(boundaries)} boundaries)")

        # Build output structure
        output = self._build_output(transcript, sentences, boundaries, similarities, threshold)

        # Save to new layer architecture location
        self.save_file(session_path, 'layers/layer-3-topic-segments/data.json', output)

        # Also save to old location for backwards compatibility
        self.save_file(session_path, 'transcription-topic-segmented.json', output)

        return ActionResult(
            success=True,
            outputs=self.produces,
            duration_seconds=self.elapsed(),
            metadata={
                'sentenceCount': len(sentences),
                'topicCount': topic_count,
                'threshold': threshold,
                'averageSimilarity': round(sum(similarities) / len(similarities), 4) if similarities else 1.0
            }
        )

    # ─────────────────────────────────────────────────────────────────
    # Sentence Extraction
    # ─────────────────────────────────────────────────────────────────

    def _extract_sentences(self, transcript: Dict) -> List[Dict]:
        """Extract sentences from transcript, grouping words by punctuation and pauses."""
        # First try to get all words from paragraphs
        all_words = []
        for para in transcript.get('paragraphs', []):
            for word in para.get('words', []):
                all_words.append({
                    'word': word.get('word', ''),
                    'start': word.get('start', 0),
                    'end': word.get('end', 0)
                })

        if not all_words:
            # Fallback: use paragraph text directly
            sentences = []
            for para in transcript.get('paragraphs', []):
                text = para.get('text', '')
                if text:
                    parts = re.split(r'(?<=[.!?])\s+', text)
                    for part in parts:
                        if part.strip():
                            sentences.append({
                                'text': part.strip(),
                                'words': [],
                                'start': para.get('start', 0),
                                'end': para.get('end', 0),
                                'wordCount': len(part.split())
                            })
            return self._merge_short_sentences(sentences)

        # Group words into sentences
        sentences = []
        current_words = []
        pause_threshold = 1.5

        for i, word_obj in enumerate(all_words):
            word = word_obj.get('word', '')
            current_words.append(word_obj)

            # Check if this word ends a sentence
            is_end = False
            if re.search(r'[.!?]$', word):
                is_end = True
            elif i < len(all_words) - 1:
                pause = all_words[i + 1].get('start', 0) - word_obj.get('end', 0)
                if pause > pause_threshold:
                    is_end = True
            elif i == len(all_words) - 1:
                is_end = True

            if is_end and current_words:
                text = ' '.join(w.get('word', '') for w in current_words)
                sentences.append({
                    'text': text,
                    'words': current_words.copy(),
                    'start': current_words[0].get('start', 0),
                    'end': current_words[-1].get('end', 0),
                    'wordCount': len(current_words)
                })
                current_words = []

        return self._merge_short_sentences(sentences)

    def _merge_short_sentences(self, sentences: List[Dict], min_words: int = 5) -> List[Dict]:
        """Merge very short sentences with neighbors for better embedding quality."""
        if len(sentences) <= 1:
            return sentences

        merged = []
        i = 0
        while i < len(sentences):
            current = sentences[i]
            if current['wordCount'] < min_words:
                if merged:
                    prev = merged[-1]
                    prev['text'] = prev['text'] + ' ' + current['text']
                    prev['words'].extend(current.get('words', []))
                    prev['end'] = current['end']
                    prev['wordCount'] = len(prev['words']) if prev['words'] else len(prev['text'].split())
                elif i < len(sentences) - 1:
                    next_sent = sentences[i + 1]
                    next_sent['text'] = current['text'] + ' ' + next_sent['text']
                    next_sent['words'] = current.get('words', []) + next_sent.get('words', [])
                    next_sent['start'] = current['start']
                    next_sent['wordCount'] = len(next_sent['words']) if next_sent['words'] else len(next_sent['text'].split())
                else:
                    merged.append(current)
            else:
                merged.append(current)
            i += 1

        return merged

    # ─────────────────────────────────────────────────────────────────
    # Embeddings
    # ─────────────────────────────────────────────────────────────────

    def _get_embeddings(self, texts: List[str]) -> List[List[float]]:
        """Generate embeddings for list of texts via Bedrock."""
        embeddings = []
        total = len(texts)

        for i, text in enumerate(texts):
            if not text or not text.strip():
                embeddings.append([0.0] * EMBEDDING_DIMS)
                continue

            # Truncate if too long
            if len(text) > 32000:
                text = text[:32000]

            try:
                response = self._bedrock.invoke_model(
                    modelId=EMBEDDING_MODEL,
                    body=json.dumps({
                        'inputText': text,
                        'dimensions': EMBEDDING_DIMS,
                        'normalize': True
                    }),
                    contentType='application/json',
                    accept='application/json'
                )
                result = json.loads(response['body'].read())
                embeddings.append(result['embedding'])
            except Exception as e:
                logger.error(f"Failed to get embedding for text {i}: {e}")
                embeddings.append([0.0] * EMBEDDING_DIMS)

            # Progress logging
            if (i + 1) % 20 == 0 or i + 1 == total:
                logger.info(f"  Embedded {i + 1}/{total} sentences")

        return embeddings

    # ─────────────────────────────────────────────────────────────────
    # Similarity Detection
    # ─────────────────────────────────────────────────────────────────

    def _cosine_similarity(self, a: List[float], b: List[float]) -> float:
        """Compute cosine similarity between two vectors."""
        dot = sum(x * y for x, y in zip(a, b))
        norm_a = math.sqrt(sum(x * x for x in a))
        norm_b = math.sqrt(sum(x * x for x in b))
        if norm_a == 0 or norm_b == 0:
            return 0.0
        return dot / (norm_a * norm_b)

    def _avg_embedding(self, embeddings: List[List[float]]) -> List[float]:
        """Compute average of embedding vectors."""
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

    def _detect_boundaries_windowed(
        self,
        embeddings: List[List[float]],
        threshold: float,
        window_size: int = 3
    ) -> Tuple[List[int], List[float]]:
        """
        Detect topic boundaries using sliding window approach.

        Compares average embedding of sentences before and after each point.
        """
        if len(embeddings) < 2:
            return [], []

        boundaries = []
        similarities = []

        for i in range(1, len(embeddings)):
            # Window before
            start = max(0, i - window_size)
            before = self._avg_embedding(embeddings[start:i])

            # Window after
            end = min(len(embeddings), i + window_size)
            after = self._avg_embedding(embeddings[i:end])

            sim = self._cosine_similarity(before, after)
            similarities.append(sim)

            if sim < threshold:
                boundaries.append(i)

        return boundaries, similarities

    # ─────────────────────────────────────────────────────────────────
    # Output Building
    # ─────────────────────────────────────────────────────────────────

    def _build_output(
        self,
        transcript: Dict,
        sentences: List[Dict],
        boundaries: List[int],
        similarities: List[float],
        threshold: float
    ) -> Dict:
        """Build output structure with topic-segmented paragraphs."""
        # Build new paragraphs from sentences
        new_paragraphs = []
        boundary_set = set(boundaries)
        current_sentences = []
        current_words = []
        para_idx = 0

        for i, sentence in enumerate(sentences):
            if i in boundary_set and current_sentences:
                # Save current paragraph
                text = ' '.join(s['text'] for s in current_sentences)
                start_time = current_sentences[0]['start']
                end_time = current_sentences[-1]['end']
                new_paragraphs.append({
                    'id': f'para-topic-{para_idx}',
                    'text': text,
                    'words': current_words.copy(),
                    'segments': [],
                    'chunkIds': [f'topic-{para_idx + 1}'],
                    'start': start_time,
                    'end': end_time,
                    'duration': end_time - start_time,
                    'wordCount': len(current_words),
                    'isTopicStart': True,
                    'topicSimilarity': similarities[i - 1] if i > 0 and i - 1 < len(similarities) else 1.0,
                    'sentenceCount': len(current_sentences)
                })
                para_idx += 1
                current_sentences = []
                current_words = []

            current_sentences.append(sentence)
            current_words.extend(sentence.get('words', []))

        # Last paragraph
        if current_sentences:
            text = ' '.join(s['text'] for s in current_sentences)
            start_time = current_sentences[0]['start']
            end_time = current_sentences[-1]['end']
            new_paragraphs.append({
                'id': f'para-topic-{para_idx}',
                'text': text,
                'words': current_words.copy(),
                'segments': [],
                'chunkIds': [f'topic-{para_idx + 1}'],
                'start': start_time,
                'end': end_time,
                'duration': end_time - start_time,
                'wordCount': len(current_words),
                'isTopicStart': para_idx == 0,
                'topicSimilarity': 1.0,
                'sentenceCount': len(current_sentences)
            })

        # Mark first paragraph as topic start
        if new_paragraphs:
            new_paragraphs[0]['isTopicStart'] = True

        # Calculate stats
        topic_count = sum(1 for p in new_paragraphs if p.get('isTopicStart', False))
        total_words = sum(len(p.get('words', [])) for p in new_paragraphs)
        total_duration = 0
        if new_paragraphs:
            total_duration = new_paragraphs[-1].get('end', 0) - new_paragraphs[0].get('start', 0)

        avg_similarity = sum(similarities) / len(similarities) if similarities else 1.0

        return {
            'paragraphs': new_paragraphs,
            'stats': {
                'paragraphCount': len(new_paragraphs),
                'totalWords': total_words,
                'totalDuration': total_duration,
                'averageWordsPerParagraph': round(total_words / len(new_paragraphs), 2) if new_paragraphs else 0,
                'wordsPerMinute': round(total_words / (total_duration / 60), 2) if total_duration > 0 else 0
            },
            'metadata': {
                'topicSegmented': True,
                'topicSegmentedAt': datetime.now(timezone.utc).isoformat(),
                'topicCount': topic_count,
                'topicThreshold': threshold,
                'embeddingModel': EMBEDDING_MODEL,
                'embeddingDimensions': EMBEDDING_DIMS,
                'segmentationMethod': 'sentence-level',
                'sentenceCount': len(sentences),
                'action': self.name
            },
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
            'version': transcript.get('version', '1.0') + '-sentence-topics'
        }
