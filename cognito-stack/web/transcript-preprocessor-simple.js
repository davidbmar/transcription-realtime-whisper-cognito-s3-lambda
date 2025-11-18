#!/usr/bin/env node

/**
 * Simple Transcript Preprocessor
 *
 * NO DEDUPLICATION - Just organizes segments by chunk
 * Shows exactly what WhisperLive produced
 */

class TranscriptPreprocessorSimple {
  constructor(options = {}) {
    // No processing options - just pass through
  }

  /**
   * Process a list of transcript chunks
   * @param {Array} chunks - Array of chunk objects with segments
   * @returns {Object} Organized transcript with NO deduplication
   */
  process(chunks) {
    // Just flatten and organize by chunk - NO merging or deduplication
    const allSegments = this.flattenSegments(chunks);
    const paragraphs = this.organizeByChunk(allSegments);
    const stats = this.generateStats(paragraphs);

    return {
      paragraphs,
      stats,
      originalSegmentCount: allSegments.length,
      processedSegmentCount: allSegments.length
    };
  }

  /**
   * Flatten segments from all chunks, adding chunk metadata
   */
  flattenSegments(chunks) {
    const segments = [];

    chunks.forEach((chunk, chunkIndex) => {
      if (!chunk.segments || !Array.isArray(chunk.segments)) {
        return;
      }

      chunk.segments.forEach(segment => {
        segments.push({
          ...segment,
          chunkIndex,
          chunkId: chunk.chunkId || `chunk-${String(chunkIndex).padStart(3, '0')}`
        });
      });
    });

    // Sort by start time
    return segments.sort((a, b) => a.start - b.start);
  }

  /**
   * Organize segments by chunk (one paragraph per chunk)
   */
  organizeByChunk(segments) {
    if (segments.length === 0) return [];

    const paragraphs = [];
    let currentChunkId = null;
    let currentParagraph = null;

    segments.forEach((segment, index) => {
      // Start new paragraph when chunk changes
      if (segment.chunkId !== currentChunkId) {
        // Save previous paragraph
        if (currentParagraph) {
          paragraphs.push(this.finalizeParagraph(currentParagraph));
        }

        // Start new paragraph
        currentChunkId = segment.chunkId;
        currentParagraph = {
          segments: [segment],
          words: segment.words || [],
          chunkIds: [segment.chunkId],
          start: segment.start,
          end: segment.end
        };
      } else {
        // Add to current paragraph
        currentParagraph.segments.push(segment);
        currentParagraph.words.push(...(segment.words || []));
        currentParagraph.end = segment.end;
      }
    });

    // Add final paragraph
    if (currentParagraph) {
      paragraphs.push(this.finalizeParagraph(currentParagraph));
    }

    return paragraphs;
  }

  /**
   * Finalize a paragraph object
   */
  finalizeParagraph(para) {
    return {
      id: `para-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
      text: para.words.map(w => w.word).join(' ').trim(),
      words: para.words,
      segments: para.segments,
      chunkIds: para.chunkIds,
      start: para.start,
      end: para.end,
      duration: para.end - para.start,
      wordCount: para.words.length
    };
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
}

// Export for use in Node.js or browser
if (typeof module !== 'undefined' && module.exports) {
  module.exports = TranscriptPreprocessorSimple;
}

// For browser usage
if (typeof window !== 'undefined') {
  window.TranscriptPreprocessorSimple = TranscriptPreprocessorSimple;
  // Also expose as the default
  window.TranscriptPreprocessor = TranscriptPreprocessorSimple;
}
