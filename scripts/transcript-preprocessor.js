#!/usr/bin/env node

/**
 * Transcript Preprocessor
 *
 * Processes raw WhisperLive transcription chunks to:
 * 1. Remove duplicate/overlapping text at segment boundaries
 * 2. Merge fragments into coherent paragraphs
 * 3. Preserve word-level timing for audio sync
 * 4. Maintain chunk references for original audio playback
 */

class TranscriptPreprocessor {
  constructor(options = {}) {
    this.similarityThreshold = options.similarityThreshold || 0.7;
    this.pauseThreshold = options.pauseThreshold || 1.0; // seconds between segments to merge
    this.minParagraphWords = options.minParagraphWords || 15;
  }

  /**
   * Process a list of transcript chunks
   * @param {Array} chunks - Array of chunk objects with segments
   * @returns {Object} Processed transcript with deduplicated paragraphs
   */
  process(chunks) {
    // Step 1: Flatten all segments with chunk metadata
    const allSegments = this.flattenSegments(chunks);

    // Step 2: Deduplicate overlapping segments
    const dedupedSegments = this.deduplicateSegments(allSegments);

    // Step 3: Merge into paragraphs
    const paragraphs = this.mergeParagraphs(dedupedSegments);

    // Step 4: Generate statistics
    const stats = this.generateStats(paragraphs, allSegments);

    return {
      paragraphs,
      stats,
      originalSegmentCount: allSegments.length,
      processedSegmentCount: dedupedSegments.length
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
   * Remove duplicate/overlapping segments
   */
  deduplicateSegments(segments) {
    if (segments.length === 0) return [];

    const deduped = [];
    let lastSegment = null;

    for (const segment of segments) {
      if (!lastSegment) {
        deduped.push(segment);
        lastSegment = segment;
        continue;
      }

      // Check if this segment is similar to the last one (overlap/duplicate)
      const similarity = this.calculateSimilarity(
        this.getSegmentText(lastSegment),
        this.getSegmentText(segment)
      );

      if (similarity > this.similarityThreshold) {
        // This is likely a duplicate, use the one with more words
        const lastWordCount = lastSegment.words?.length || 0;
        const currentWordCount = segment.words?.length || 0;

        if (currentWordCount > lastWordCount) {
          // Replace last segment with this one
          deduped[deduped.length - 1] = segment;
          lastSegment = segment;
        }
        // Otherwise skip this duplicate
      } else {
        // Check for partial overlap at word level
        const merged = this.mergeOverlappingWords(lastSegment, segment);

        if (merged) {
          // Replace last segment with merged version
          deduped[deduped.length - 1] = merged.merged;
          if (merged.remainder) {
            deduped.push(merged.remainder);
            lastSegment = merged.remainder;
          } else {
            lastSegment = merged.merged;
          }
        } else {
          // No overlap, add as new segment
          deduped.push(segment);
          lastSegment = segment;
        }
      }
    }

    return deduped;
  }

  /**
   * Merge overlapping words between consecutive segments
   */
  mergeOverlappingWords(seg1, seg2) {
    if (!seg1.words || !seg2.words) return null;

    const words1 = seg1.words.map(w => this.normalizeWord(w.word));
    const words2 = seg2.words.map(w => this.normalizeWord(w.word));

    // Find longest overlapping suffix of seg1 with prefix of seg2
    let maxOverlap = 0;
    const maxCheck = Math.min(words1.length, words2.length, 10); // Check up to 10 words

    for (let i = 1; i <= maxCheck; i++) {
      const suffix = words1.slice(-i);
      const prefix = words2.slice(0, i);

      if (this.arraysEqual(suffix, prefix)) {
        maxOverlap = i;
      }
    }

    if (maxOverlap > 0) {
      // Merge: take all of seg1 + seg2 without the overlapping prefix
      const mergedWords = [
        ...seg1.words,
        ...seg2.words.slice(maxOverlap)
      ];

      const merged = {
        ...seg1,
        words: mergedWords,
        text: mergedWords.map(w => w.word).join(' '),
        end: seg2.end,
        merged: true,
        originalSegments: [seg1, seg2]
      };

      return { merged, remainder: null };
    }

    return null;
  }

  /**
   * Merge segments into coherent paragraphs based on pauses
   */
  mergeParagraphs(segments) {
    if (segments.length === 0) return [];

    const paragraphs = [];
    let currentParagraph = {
      segments: [segments[0]],
      words: segments[0].words || [],
      chunkIds: new Set([segments[0].chunkId]),
      start: segments[0].start,
      end: segments[0].end
    };

    for (let i = 1; i < segments.length; i++) {
      const prevSegment = segments[i - 1];
      const currSegment = segments[i];

      const pause = currSegment.start - prevSegment.end;

      // Check if we should start a new paragraph
      const shouldBreak = pause > this.pauseThreshold ||
                         this.detectSentenceEnd(prevSegment);

      if (shouldBreak && currentParagraph.words.length >= this.minParagraphWords) {
        // Finalize current paragraph
        paragraphs.push(this.finalizeParagraph(currentParagraph));

        // Start new paragraph
        currentParagraph = {
          segments: [currSegment],
          words: currSegment.words || [],
          chunkIds: new Set([currSegment.chunkId]),
          start: currSegment.start,
          end: currSegment.end
        };
      } else {
        // Add to current paragraph
        currentParagraph.segments.push(currSegment);
        currentParagraph.words.push(...(currSegment.words || []));
        currentParagraph.chunkIds.add(currSegment.chunkId);
        currentParagraph.end = currSegment.end;
      }
    }

    // Add final paragraph
    if (currentParagraph.segments.length > 0) {
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
      text: para.words.map(w => w.word).join(' '),
      words: para.words,
      segments: para.segments,
      chunkIds: Array.from(para.chunkIds),
      start: para.start,
      end: para.end,
      duration: para.end - para.start,
      wordCount: para.words.length
    };
  }

  /**
   * Detect if a segment ends a sentence
   */
  detectSentenceEnd(segment) {
    const text = this.getSegmentText(segment).trim();
    return /[.!?]$/.test(text);
  }

  /**
   * Calculate text similarity using Jaccard similarity
   */
  calculateSimilarity(text1, text2) {
    const words1 = new Set(text1.toLowerCase().split(/\s+/));
    const words2 = new Set(text2.toLowerCase().split(/\s+/));

    const intersection = new Set([...words1].filter(w => words2.has(w)));
    const union = new Set([...words1, ...words2]);

    return union.size > 0 ? intersection.size / union.size : 0;
  }

  /**
   * Get text from segment (words or text field)
   */
  getSegmentText(segment) {
    if (segment.words && segment.words.length > 0) {
      return segment.words.map(w => w.word).join(' ');
    }
    return segment.text || '';
  }

  /**
   * Normalize word for comparison
   */
  normalizeWord(word) {
    return word.toLowerCase().trim().replace(/[,.\-!?;:]/g, '');
  }

  /**
   * Check if two arrays are equal
   */
  arraysEqual(arr1, arr2) {
    if (arr1.length !== arr2.length) return false;
    return arr1.every((val, idx) => val === arr2[idx]);
  }

  /**
   * Generate statistics about the processing
   */
  generateStats(paragraphs, originalSegments) {
    const totalWords = paragraphs.reduce((sum, p) => sum + p.wordCount, 0);
    const totalDuration = paragraphs.reduce((sum, p) => sum + p.duration, 0);

    return {
      paragraphCount: paragraphs.length,
      totalWords,
      totalDuration,
      averageWordsPerParagraph: totalWords / paragraphs.length,
      wordsPerMinute: totalDuration > 0 ? (totalWords / totalDuration) * 60 : 0
    };
  }
}

// Export for use in Node.js or browser
if (typeof module !== 'undefined' && module.exports) {
  module.exports = TranscriptPreprocessor;
}

// For browser usage
if (typeof window !== 'undefined') {
  window.TranscriptPreprocessor = TranscriptPreprocessor;
}
