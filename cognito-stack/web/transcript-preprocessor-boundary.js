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
    console.log(`[Boundary Preprocessor] Processing ${chunks.length} chunks`);

    // IMPORTANT: Sort chunks by index to ensure correct order
    const sortedChunks = [...chunks].sort((a, b) => (a.chunkIndex || 0) - (b.chunkIndex || 0));

    console.log('[Boundary Preprocessor] Chunk order:', sortedChunks.map(c => c.chunkId || c.chunkIndex).join(', '));

    // Organize segments by chunk
    const chunkGroups = this.organizeByChunk(sortedChunks);

    // Deduplicate only at chunk boundaries
    const dedupedChunks = this.deduplicateBoundaries(chunkGroups);

    // Create paragraphs (one per chunk)
    const paragraphs = this.createParagraphs(dedupedChunks);

    // Generate stats
    const stats = this.generateStats(paragraphs);

    console.log(`[Boundary Preprocessor] Created ${paragraphs.length} paragraphs`);

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
        const removedWords = currWords.slice(0, overlapLength).map(w => w.word).join(' ');
        console.log(`[Boundary Dedup] ${prevChunk.chunkId} → ${currChunk.chunkId}: Removing ${overlapLength} words`);
        console.log(`  Previous chunk ends with: "${prevWords.slice(-overlapLength).map(w => w.word).join(' ')}"`);
        console.log(`  Current chunk starts with: "${removedWords}" ← REMOVING THIS`);
        console.log(`  Current chunk now starts: "${currWords.slice(overlapLength, overlapLength + 5).map(w => w.word).join(' ')}..."`);

        currChunk.words = currWords.slice(overlapLength);

        // Update timing
        if (currChunk.words.length > 0) {
          currChunk.start = currChunk.words[0].start;
        }
      } else {
        console.log(`[Boundary Dedup] ${prevChunk.chunkId} → ${currChunk.chunkId}: No overlap detected`);
      }

      deduped.push(currChunk);
    }

    return deduped;
  }

  /**
   * Create one paragraph per chunk
   */
  createParagraphs(chunkGroups) {
    // Calculate cumulative time offset for each chunk
    // This handles variable chunk durations (e.g., 5s, 30s, 2min, etc.)
    let cumulativeTime = 0;

    return chunkGroups.map((chunk, index) => {
      // Store the current cumulative time as the offset for this chunk
      const timeOffset = cumulativeTime;

      // Convert word timestamps to absolute time
      // BUG FIX: Words had chunk-relative timestamps which caused issues
      // when topic segmentation merged words from different chunks
      const absoluteWords = chunk.words.map(w => ({
        ...w,
        start: w.start + timeOffset,
        end: w.end + timeOffset
      }));

      // Create paragraph with absolute timestamps
      const paragraph = {
        id: `para-${chunk.chunkId}`,
        text: absoluteWords.map(w => w.word).join(' ').trim(),
        words: absoluteWords,  // Now with absolute timestamps
        segments: chunk.segments,
        chunkIds: [chunk.chunkId],
        chunkIndex: chunk.chunkIndex,
        start: chunk.start + timeOffset,  // Add offset to make absolute time
        end: chunk.end + timeOffset,      // Add offset to make absolute time
        duration: chunk.end - chunk.start,
        wordCount: absoluteWords.length
      };

      // Update cumulative time for next chunk
      // Use the actual chunk duration (end - start) to handle variable chunk sizes
      cumulativeTime += chunk.end - chunk.start;

      return paragraph;
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
