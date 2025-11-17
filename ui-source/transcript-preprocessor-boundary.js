#!/usr/bin/env node

/**
 * Boundary-Only Deduplication Preprocessor
 *
 * ONLY removes duplicates at chunk boundaries
 * - Case-insensitive word comparison
 * - Only checks last words of chunk N vs first words of chunk N+1
 * - Removes duplicate from beginning of chunk N+1
 * - Preserves all other content exactly as WhisperLive produced it
 */

class TranscriptPreprocessorBoundary {
  constructor(options = {}) {
    this.maxBoundaryWords = options.maxBoundaryWords || 10; // Check up to 10 words at boundaries
  }

  /**
   * Process transcript chunks
   */
  process(chunks) {
    // Organize segments by chunk
    const chunkGroups = this.organizeByChunk(chunks);

    // Deduplicate only at chunk boundaries
    const dedupedChunks = this.deduplicateBoundaries(chunkGroups);

    // Create paragraphs (one per chunk)
    const paragraphs = this.createParagraphs(dedupedChunks);

    // Generate stats
    const stats = this.generateStats(paragraphs);

    return {
      paragraphs,
      stats,
      originalSegmentCount: chunks.reduce((sum, c) => sum + (c.segments?.length || 0), 0),
      processedSegmentCount: paragraphs.reduce((sum, p) => sum + p.segments.length, 0)
    };
  }

  /**
   * Organize all segments by their chunk
   */
  organizeByChunk(chunks) {
    const chunkGroups = [];

    chunks.forEach((chunk, chunkIndex) => {
      if (!chunk.segments || !Array.isArray(chunk.segments)) {
        return;
      }

      const chunkId = chunk.chunkId || `chunk-${String(chunkIndex).padStart(3, '0')}`;

      // Collect all words from all segments in this chunk
      const allWords = [];
      const allSegments = [];

      chunk.segments.forEach(segment => {
        if (segment.words && segment.words.length > 0) {
          allWords.push(...segment.words);
          allSegments.push(segment);
        }
      });

      if (allWords.length > 0) {
        chunkGroups.push({
          chunkIndex,
          chunkId,
          words: allWords,
          segments: allSegments,
          start: allWords[0].start,
          end: allWords[allWords.length - 1].end
        });
      }
    });

    return chunkGroups;
  }

  /**
   * Deduplicate ONLY at chunk boundaries
   */
  deduplicateBoundaries(chunkGroups) {
    if (chunkGroups.length === 0) return [];

    const deduped = [chunkGroups[0]]; // First chunk is always kept as-is

    for (let i = 1; i < chunkGroups.length; i++) {
      const prevChunk = chunkGroups[i - 1];
      const currChunk = chunkGroups[i];

      // Get last N words from previous chunk
      const prevWords = prevChunk.words;
      const prevTail = prevWords.slice(-this.maxBoundaryWords);

      // Get first N words from current chunk
      const currWords = [...currChunk.words]; // Copy so we can modify
      const currHead = currWords.slice(0, this.maxBoundaryWords);

      // Find longest overlap
      let overlapLength = 0;
      for (let len = Math.min(prevTail.length, currHead.length); len > 0; len--) {
        const prevSlice = prevTail.slice(-len).map(w => this.normalizeWord(w.word));
        const currSlice = currHead.slice(0, len).map(w => this.normalizeWord(w.word));

        if (this.arraysEqual(prevSlice, currSlice)) {
          overlapLength = len;
          break;
        }
      }

      // Remove overlap from current chunk
      if (overlapLength > 0) {
        console.log(`[Boundary Dedup] Chunk ${currChunk.chunkId}: Removing ${overlapLength} duplicate words from start`);
        console.log(`  Removed: ${currWords.slice(0, overlapLength).map(w => w.word).join(' ')}`);

        currChunk.words = currWords.slice(overlapLength);

        // Update timing
        if (currChunk.words.length > 0) {
          currChunk.start = currChunk.words[0].start;
        }
      }

      deduped.push(currChunk);
    }

    return deduped;
  }

  /**
   * Create one paragraph per chunk
   */
  createParagraphs(chunkGroups) {
    return chunkGroups.map((chunk, index) => {
      return {
        id: `para-${chunk.chunkId}`,
        text: chunk.words.map(w => w.word).join(' ').trim(),
        words: chunk.words,
        segments: chunk.segments,
        chunkIds: [chunk.chunkId],
        chunkIndex: chunk.chunkIndex,
        start: chunk.start,
        end: chunk.end,
        duration: chunk.end - chunk.start,
        wordCount: chunk.words.length
      };
    });
  }

  /**
   * Generate statistics
   */
  generateStats(paragraphs) {
    const totalWords = paragraphs.reduce((sum, p) => sum + p.wordCount, 0);
    const totalDuration = paragraphs.reduce((sum, p) => sum + p.duration, 0);

    return {
      paragraphCount: paragraphs.length,
      totalWords,
      totalDuration,
      averageWordsPerParagraph: paragraphs.length > 0 ? totalWords / paragraphs.length : 0,
      wordsPerMinute: totalDuration > 0 ? (totalWords / totalDuration) * 60 : 0
    };
  }

  /**
   * Normalize word for comparison (case-insensitive, remove punctuation)
   */
  normalizeWord(word) {
    return word.toLowerCase().trim().replace(/[^\w]/g, '');
  }

  /**
   * Compare two word arrays
   */
  arraysEqual(arr1, arr2) {
    if (arr1.length !== arr2.length) return false;
    return arr1.every((val, idx) => val === arr2[idx]);
  }
}

// Export for use in Node.js or browser
if (typeof module !== 'undefined' && module.exports) {
  module.exports = TranscriptPreprocessorBoundary;
}

// For browser usage
if (typeof window !== 'undefined') {
  window.TranscriptPreprocessorBoundary = TranscriptPreprocessorBoundary;
  // Set as default
  window.TranscriptPreprocessor = TranscriptPreprocessorBoundary;
}
