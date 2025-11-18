#!/usr/bin/env node

/**
 * Transcript Plugin Framework
 *
 * Extensible plugin system for processing, searching, and modifying transcripts
 */

class TranscriptPluginManager {
  constructor() {
    this.plugins = new Map();
    this.registerBuiltInPlugins();
  }

  /**
   * Register a plugin
   */
  register(name, plugin) {
    if (!plugin.execute || typeof plugin.execute !== 'function') {
      throw new Error(`Plugin ${name} must have an execute() method`);
    }

    this.plugins.set(name, {
      ...plugin,
      name,
      enabled: plugin.enabled !== false
    });
  }

  /**
   * Execute a plugin
   */
  async execute(pluginName, context) {
    const plugin = this.plugins.get(pluginName);

    if (!plugin) {
      throw new Error(`Plugin ${pluginName} not found`);
    }

    if (!plugin.enabled) {
      throw new Error(`Plugin ${pluginName} is disabled`);
    }

    return await plugin.execute(context);
  }

  /**
   * Get all registered plugins
   */
  listPlugins() {
    return Array.from(this.plugins.values()).map(p => ({
      name: p.name,
      description: p.description,
      category: p.category,
      enabled: p.enabled
    }));
  }

  /**
   * Register built-in plugins
   */
  registerBuiltInPlugins() {
    // Search Plugin
    this.register('search', {
      description: 'Search for text in transcript',
      category: 'search',
      execute: async ({ paragraphs, query, options = {} }) => {
        const results = [];
        const caseSensitive = options.caseSensitive || false;
        const regex = options.regex || false;

        const searchTerm = regex ? new RegExp(query, caseSensitive ? '' : 'i') :
                          caseSensitive ? query : query.toLowerCase();

        paragraphs.forEach((para, index) => {
          const text = caseSensitive ? para.text : para.text.toLowerCase();
          let match = false;

          if (regex) {
            match = searchTerm.test(para.text);
          } else {
            match = text.includes(searchTerm);
          }

          if (match) {
            // Find word-level matches
            const wordMatches = para.words.filter(word => {
              const wordText = caseSensitive ? word.word : word.word.toLowerCase();
              return regex ? searchTerm.test(word.word) : wordText.includes(searchTerm);
            });

            results.push({
              paragraphIndex: index,
              paragraph: para,
              matchCount: wordMatches.length,
              words: wordMatches,
              context: this.getContext(para, 50)
            });
          }
        });

        return {
          query,
          totalMatches: results.length,
          results
        };
      }
    });

    // Find and Replace Plugin
    this.register('replace', {
      description: 'Find and replace text in transcript',
      category: 'edit',
      execute: async ({ paragraphs, find, replace, options = {} }) => {
        const caseSensitive = options.caseSensitive || false;
        const replaceAll = options.replaceAll !== false;
        const modified = [];

        const searchRegex = new RegExp(
          find.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'),
          caseSensitive ? (replaceAll ? 'g' : '') : (replaceAll ? 'gi' : 'i')
        );

        paragraphs.forEach((para, index) => {
          const originalText = para.text;
          const newText = originalText.replace(searchRegex, replace);

          if (newText !== originalText) {
            para.text = newText;
            para.edited = true;
            para.editHistory = para.editHistory || [];
            para.editHistory.push({
              timestamp: Date.now(),
              operation: 'replace',
              from: originalText,
              to: newText
            });

            modified.push({
              paragraphIndex: index,
              original: originalText,
              modified: newText
            });
          }
        });

        return {
          modifiedCount: modified.length,
          modifications: modified
        };
      }
    });

    // Highlight Keywords Plugin
    this.register('highlight', {
      description: 'Highlight keywords in transcript',
      category: 'annotate',
      execute: async ({ paragraphs, keywords, color = 'yellow' }) => {
        const highlighted = [];

        paragraphs.forEach((para, index) => {
          para.highlights = para.highlights || [];

          keywords.forEach(keyword => {
            const regex = new RegExp(keyword, 'gi');
            let match;

            while ((match = regex.exec(para.text)) !== null) {
              para.highlights.push({
                keyword,
                start: match.index,
                end: match.index + keyword.length,
                color
              });

              highlighted.push({
                paragraphIndex: index,
                keyword,
                position: match.index
              });
            }
          });
        });

        return {
          highlightCount: highlighted.length,
          highlights: highlighted
        };
      }
    });

    // Extract Action Items Plugin
    this.register('extract-actions', {
      description: 'Extract action items from transcript',
      category: 'analyze',
      execute: async ({ paragraphs }) => {
        const actionPatterns = [
          /\b(todo|to do|action item):\s*(.+)/gi,
          /\b(need to|should|must|have to)\s+(.+)/gi,
          /\b(follow up|followup)\s+(.+)/gi
        ];

        const actions = [];

        paragraphs.forEach((para, index) => {
          actionPatterns.forEach(pattern => {
            let match;
            while ((match = pattern.exec(para.text)) !== null) {
              actions.push({
                paragraphIndex: index,
                text: match[0],
                timestamp: para.start,
                context: para.text
              });
            }
          });
        });

        return {
          actionCount: actions.length,
          actions
        };
      }
    });

    // Summarize Plugin
    this.register('summarize', {
      description: 'Generate paragraph summaries',
      category: 'analyze',
      execute: async ({ paragraphs, maxLength = 50 }) => {
        const summaries = paragraphs.map((para, index) => {
          const words = para.text.split(/\s+/);
          const summary = words.slice(0, maxLength).join(' ') +
                         (words.length > maxLength ? '...' : '');

          return {
            paragraphIndex: index,
            summary,
            wordCount: para.wordCount,
            duration: para.duration
          };
        });

        return {
          summaries,
          totalParagraphs: paragraphs.length
        };
      }
    });

    // Extract Speaker Transitions Plugin
    this.register('speaker-transitions', {
      description: 'Identify speaker changes (if diarization available)',
      category: 'analyze',
      execute: async ({ paragraphs }) => {
        const transitions = [];
        let lastSpeaker = null;

        paragraphs.forEach((para, index) => {
          const speaker = para.speaker || 'Unknown';

          if (speaker !== lastSpeaker) {
            transitions.push({
              paragraphIndex: index,
              speaker,
              timestamp: para.start,
              previousSpeaker: lastSpeaker
            });
            lastSpeaker = speaker;
          }
        });

        return {
          transitionCount: transitions.length,
          transitions,
          uniqueSpeakers: [...new Set(transitions.map(t => t.speaker))]
        };
      }
    });

    // Word Cloud Data Plugin
    this.register('word-frequency', {
      description: 'Generate word frequency data',
      category: 'analyze',
      execute: async ({ paragraphs, minLength = 4, excludeCommon = true }) => {
        const commonWords = new Set([
          'the', 'be', 'to', 'of', 'and', 'a', 'in', 'that', 'have', 'i',
          'it', 'for', 'not', 'on', 'with', 'he', 'as', 'you', 'do', 'at',
          'this', 'but', 'his', 'by', 'from', 'they', 'we', 'say', 'her', 'she',
          'or', 'an', 'will', 'my', 'one', 'all', 'would', 'there', 'their'
        ]);

        const frequencies = new Map();

        paragraphs.forEach(para => {
          para.words.forEach(wordObj => {
            const word = wordObj.word.toLowerCase().replace(/[^\w]/g, '');

            if (word.length >= minLength && !(excludeCommon && commonWords.has(word))) {
              frequencies.set(word, (frequencies.get(word) || 0) + 1);
            }
          });
        });

        const sorted = Array.from(frequencies.entries())
          .sort((a, b) => b[1] - a[1])
          .map(([word, count]) => ({ word, count }));

        return {
          totalUniqueWords: sorted.length,
          topWords: sorted.slice(0, 50),
          allWords: sorted
        };
      }
    });

    // Export to Formats Plugin
    this.register('export', {
      description: 'Export transcript to various formats',
      category: 'export',
      execute: async ({ paragraphs, format = 'plain' }) => {
        const exporters = {
          plain: () => paragraphs.map(p => p.text).join('\n\n'),

          markdown: () => paragraphs.map((p, i) => {
            const time = this.formatTime(p.start);
            return `## [${time}]\n\n${p.text}\n`;
          }).join('\n'),

          srt: () => paragraphs.map((p, i) => {
            const start = this.formatSRT(p.start);
            const end = this.formatSRT(p.end);
            return `${i + 1}\n${start} --> ${end}\n${p.text}\n`;
          }).join('\n'),

          json: () => JSON.stringify(paragraphs, null, 2),

          html: () => `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Transcript</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 800px; margin: 40px auto; line-height: 1.6; }
    .paragraph { margin-bottom: 20px; }
    .timestamp { color: #666; font-size: 0.9em; }
  </style>
</head>
<body>
${paragraphs.map(p => `
  <div class="paragraph">
    <span class="timestamp">[${this.formatTime(p.start)}]</span>
    <p>${p.text}</p>
  </div>
`).join('')}
</body>
</html>`
        };

        if (!exporters[format]) {
          throw new Error(`Unknown export format: ${format}`);
        }

        return {
          format,
          content: exporters[format]()
        };
      }
    });
  }

  /**
   * Get context around a paragraph
   */
  getContext(para, maxChars) {
    if (para.text.length <= maxChars) {
      return para.text;
    }
    return para.text.substring(0, maxChars) + '...';
  }

  /**
   * Format time as MM:SS
   */
  formatTime(seconds) {
    const mins = Math.floor(seconds / 60);
    const secs = Math.floor(seconds % 60);
    return `${mins}:${secs.toString().padStart(2, '0')}`;
  }

  /**
   * Format time for SRT (00:00:00,000)
   */
  formatSRT(seconds) {
    const hours = Math.floor(seconds / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    const secs = Math.floor(seconds % 60);
    const ms = Math.floor((seconds % 1) * 1000);

    return `${hours.toString().padStart(2, '0')}:${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')},${ms.toString().padStart(3, '0')}`;
  }
}

// Export for use in Node.js or browser
if (typeof module !== 'undefined' && module.exports) {
  module.exports = TranscriptPluginManager;
}

// For browser usage
if (typeof window !== 'undefined') {
  window.TranscriptPluginManager = TranscriptPluginManager;
}
