/**
 * Upload Queue - Automatic Retry with Exponential Backoff
 *
 * Purpose: Manage upload queue with automatic retry for failed chunks
 * - Maximum 3 concurrent uploads
 * - Exponential backoff retry (1s, 2s, 4s, 8s, 16s, 60s max)
 * - Network online/offline detection
 * - Integration with AudioStorage (IndexedDB)
 * - Event system for UI updates
 *
 * USAGE EXAMPLE:
 *
 * // 1. Initialize with AudioStorage
 * const storage = new AudioStorage();
 * await storage.init();
 *
 * const queue = new UploadQueue(storage, {
 *   maxConcurrent: 3,
 *   maxRetries: 5,
 *   getUploadUrl: async (sessionId, chunkNumber) => {
 *     // Your API call to get presigned URL
 *     return { uploadUrl: '...', s3Key: '...' };
 *   }
 * });
 *
 * // 2. Listen to events
 * queue.on('upload-start', (data) => {
 *   console.log(`Starting upload: chunk ${data.chunkNumber}`);
 * });
 *
 * queue.on('upload-complete', (data) => {
 *   console.log(`Upload complete: chunk ${data.chunkNumber}`);
 * });
 *
 * queue.on('upload-failed', (data) => {
 *   console.error(`Upload failed: chunk ${data.chunkNumber}`, data.error);
 * });
 *
 * // 3. Enqueue chunks for upload
 * await queue.enqueue(sessionId, chunkNumber);
 *
 * // 4. Pause/resume
 * queue.pause();
 * queue.resume();
 *
 * // 5. Start processing (auto-starts when first chunk is enqueued)
 * queue.start();
 */

class UploadQueue {
  constructor(audioStorage, options = {}) {
    // Dependencies
    this.storage = audioStorage;

    // Configuration
    this.maxConcurrent = options.maxConcurrent || 3;
    this.maxRetries = options.maxRetries || 5;
    this.baseDelay = options.baseDelay || 1000; // 1 second
    this.maxDelay = options.maxDelay || 60000;  // 60 seconds
    this.getUploadUrl = options.getUploadUrl;   // Function to get presigned URL

    // State
    this.queue = [];                  // Pending uploads: [{sessionId, chunkNumber, retryCount, scheduledTime}]
    this.active = new Map();          // Active uploads: Map<key, {sessionId, chunkNumber, controller}>
    this.paused = false;
    this.isProcessing = false;
    this.isOnline = navigator.onLine;

    // Event listeners: Map<eventName, Set<handler>>
    this.eventListeners = new Map();

    // Retry timers
    this.retryTimers = new Map();

    // Statistics
    this.stats = {
      totalEnqueued: 0,
      totalUploaded: 0,
      totalFailed: 0,
      activeUploads: 0
    };

    // Setup network monitoring
    this._setupNetworkMonitoring();

    console.log('[UploadQueue] Initialized', {
      maxConcurrent: this.maxConcurrent,
      maxRetries: this.maxRetries,
      isOnline: this.isOnline
    });
  }

  /**
   * Setup network online/offline detection
   * @private
   */
  _setupNetworkMonitoring() {
    window.addEventListener('online', () => {
      console.log('[UploadQueue] Network online');
      this.isOnline = true;
      this.emit('network-online');
      this.resume();
    });

    window.addEventListener('offline', () => {
      console.log('[UploadQueue] Network offline');
      this.isOnline = false;
      this.emit('network-offline');
      this.pause();
    });
  }

  /**
   * Enqueue a chunk for upload
   * @param {string} sessionId - Session ID
   * @param {number} chunkNumber - Chunk number
   * @param {number} retryCount - Current retry count (default: 0)
   * @returns {Promise<void>}
   */
  async enqueue(sessionId, chunkNumber, retryCount = 0) {
    const key = `${sessionId}:${chunkNumber}`;

    // Check if already in queue or actively uploading
    if (this.queue.some(item => `${item.sessionId}:${item.chunkNumber}` === key)) {
      console.log(`[UploadQueue] Chunk ${chunkNumber} already in queue`);
      return;
    }

    if (this.active.has(key)) {
      console.log(`[UploadQueue] Chunk ${chunkNumber} already uploading`);
      return;
    }

    // Add to queue
    const queueItem = {
      sessionId,
      chunkNumber,
      retryCount,
      scheduledTime: Date.now()
    };

    this.queue.push(queueItem);
    this.stats.totalEnqueued++;

    console.log(`[UploadQueue] Enqueued chunk ${chunkNumber} (queue size: ${this.queue.length})`);

    this.emit('chunk-enqueued', { sessionId, chunkNumber, retryCount });

    // Auto-start processing
    if (!this.isProcessing) {
      this.start();
    }
  }

  /**
   * Enqueue a chunk with delay (for retry)
   * @param {string} sessionId - Session ID
   * @param {number} chunkNumber - Chunk number
   * @param {number} retryCount - Current retry count
   * @param {number} delay - Delay in milliseconds
   * @private
   */
  _enqueueWithDelay(sessionId, chunkNumber, retryCount, delay) {
    const key = `${sessionId}:${chunkNumber}`;

    console.log(`[UploadQueue] Scheduling retry for chunk ${chunkNumber} in ${(delay / 1000).toFixed(1)}s (attempt ${retryCount + 1}/${this.maxRetries})`);

    const timer = setTimeout(() => {
      this.retryTimers.delete(key);
      this.enqueue(sessionId, chunkNumber, retryCount);
    }, delay);

    this.retryTimers.set(key, timer);
  }

  /**
   * Start processing the upload queue
   */
  start() {
    if (this.isProcessing) {
      console.log('[UploadQueue] Already processing');
      return;
    }

    console.log('[UploadQueue] Starting queue processing');
    this.isProcessing = true;
    this.processQueue();
  }

  /**
   * Stop processing the upload queue
   */
  stop() {
    console.log('[UploadQueue] Stopping queue processing');
    this.isProcessing = false;
  }

  /**
   * Pause upload queue (e.g., when network is offline)
   */
  pause() {
    if (this.paused) return;
    console.log('[UploadQueue] Pausing queue');
    this.paused = true;
    this.emit('queue-paused');
  }

  /**
   * Resume upload queue
   */
  resume() {
    if (!this.paused) return;
    console.log('[UploadQueue] Resuming queue');
    this.paused = false;
    this.emit('queue-resumed');

    // Resume processing
    if (!this.isProcessing) {
      this.start();
    } else {
      this.processQueue();
    }
  }

  /**
   * Main queue processing loop
   * @private
   */
  async processQueue() {
    if (!this.isProcessing) return;

    // Wait if paused or offline
    if (this.paused || !this.isOnline) {
      console.log(`[UploadQueue] Processing paused (paused=${this.paused}, online=${this.isOnline})`);
      setTimeout(() => this.processQueue(), 1000);
      return;
    }

    // Process queue while we have capacity and items
    while (
      this.queue.length > 0 &&
      this.active.size < this.maxConcurrent &&
      !this.paused &&
      this.isOnline
    ) {
      // Get next item (FIFO)
      const item = this.queue.shift();

      // Skip if scheduled in the future
      if (item.scheduledTime > Date.now()) {
        this.queue.push(item); // Put it back
        break;
      }

      // Start upload
      this.uploadChunk(item.sessionId, item.chunkNumber, item.retryCount);
    }

    // Continue processing
    if (this.isProcessing) {
      setTimeout(() => this.processQueue(), 100);
    }
  }

  /**
   * Upload a single chunk
   * @param {string} sessionId - Session ID
   * @param {number} chunkNumber - Chunk number
   * @param {number} retryCount - Current retry count
   * @private
   */
  async uploadChunk(sessionId, chunkNumber, retryCount) {
    const key = `${sessionId}:${chunkNumber}`;

    try {
      // Mark as active
      const controller = new AbortController();
      this.active.set(key, { sessionId, chunkNumber, controller });
      this.stats.activeUploads = this.active.size;

      console.log(`[UploadQueue] Starting upload: chunk ${chunkNumber} (attempt ${retryCount + 1})`);

      this.emit('upload-start', {
        sessionId,
        chunkNumber,
        retryCount,
        activeUploads: this.active.size
      });

      // Get chunk from IndexedDB
      const chunk = await this.storage.getChunk(sessionId, chunkNumber);

      if (!chunk) {
        throw new Error(`Chunk ${chunkNumber} not found in storage`);
      }

      if (!chunk.audioBlob) {
        throw new Error(`Chunk ${chunkNumber} has no audio blob`);
      }

      // Update status to uploading
      await this.storage.updateChunkStatus(sessionId, chunkNumber, {
        uploadStatus: 'uploading'
      });

      // Get presigned upload URL
      if (!this.getUploadUrl) {
        throw new Error('getUploadUrl function not provided');
      }

      const { uploadUrl, s3Key } = await this.getUploadUrl(sessionId, chunkNumber, chunk.mimeType);

      // Upload to S3
      const uploadResponse = await fetch(uploadUrl, {
        method: 'PUT',
        body: chunk.audioBlob,
        headers: {
          'Content-Type': chunk.mimeType
        },
        signal: controller.signal
      });

      if (!uploadResponse.ok) {
        throw new Error(`Upload failed: ${uploadResponse.status} ${uploadResponse.statusText}`);
      }

      // Update status to uploaded
      await this.storage.updateChunkStatus(sessionId, chunkNumber, {
        uploadStatus: 'uploaded',
        s3Key: s3Key
      });

      // Success!
      this.active.delete(key);
      this.stats.activeUploads = this.active.size;
      this.stats.totalUploaded++;

      console.log(`[UploadQueue] ✓ Upload complete: chunk ${chunkNumber}`);

      this.emit('upload-complete', {
        sessionId,
        chunkNumber,
        retryCount,
        s3Key,
        size: chunk.size
      });

    } catch (error) {
      // Remove from active
      this.active.delete(key);
      this.stats.activeUploads = this.active.size;

      console.error(`[UploadQueue] ✗ Upload failed: chunk ${chunkNumber}:`, error.message);

      // Check if we should retry
      if (retryCount < this.maxRetries) {
        // Calculate exponential backoff delay
        const delay = this.calculateBackoffDelay(retryCount);

        // Update status to failed (temporarily)
        await this.storage.updateChunkStatus(sessionId, chunkNumber, {
          uploadStatus: 'failed',
          lastError: error.message
        });

        this.emit('upload-retry', {
          sessionId,
          chunkNumber,
          retryCount,
          nextRetry: retryCount + 1,
          delay,
          error: error.message
        });

        // Schedule retry
        this._enqueueWithDelay(sessionId, chunkNumber, retryCount + 1, delay);

      } else {
        // Max retries exceeded
        this.stats.totalFailed++;

        await this.storage.updateChunkStatus(sessionId, chunkNumber, {
          uploadStatus: 'failed',
          lastError: `Max retries exceeded: ${error.message}`
        });

        console.error(`[UploadQueue] Max retries exceeded for chunk ${chunkNumber}`);

        this.emit('upload-failed', {
          sessionId,
          chunkNumber,
          retryCount,
          error: error.message
        });
      }
    }
  }

  /**
   * Calculate exponential backoff delay
   * @param {number} retryCount - Current retry count
   * @returns {number} Delay in milliseconds
   */
  calculateBackoffDelay(retryCount) {
    const delay = Math.min(
      this.baseDelay * Math.pow(2, retryCount),
      this.maxDelay
    );
    return delay;
  }

  /**
   * Cancel upload for a specific chunk
   * @param {string} sessionId - Session ID
   * @param {number} chunkNumber - Chunk number
   */
  cancelUpload(sessionId, chunkNumber) {
    const key = `${sessionId}:${chunkNumber}`;

    // Cancel active upload
    const activeUpload = this.active.get(key);
    if (activeUpload) {
      activeUpload.controller.abort();
      this.active.delete(key);
      this.stats.activeUploads = this.active.size;
      console.log(`[UploadQueue] Cancelled active upload: chunk ${chunkNumber}`);
    }

    // Remove from queue
    this.queue = this.queue.filter(
      item => !(item.sessionId === sessionId && item.chunkNumber === chunkNumber)
    );

    // Cancel retry timer
    const timer = this.retryTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.retryTimers.delete(key);
      console.log(`[UploadQueue] Cancelled retry timer: chunk ${chunkNumber}`);
    }

    this.emit('upload-cancelled', { sessionId, chunkNumber });
  }

  /**
   * Get queue statistics
   * @returns {Object} Statistics
   */
  getStats() {
    return {
      ...this.stats,
      queueLength: this.queue.length,
      activeUploads: this.active.size,
      scheduledRetries: this.retryTimers.size,
      isOnline: this.isOnline,
      isPaused: this.paused,
      isProcessing: this.isProcessing
    };
  }

  /**
   * Retry all failed chunks for a session
   * @param {string} sessionId - Session ID
   */
  async retryFailedChunks(sessionId) {
    const failedChunks = await this.storage.getFailedChunks(sessionId);

    console.log(`[UploadQueue] Retrying ${failedChunks.length} failed chunks for session ${sessionId}`);

    for (const chunk of failedChunks) {
      // Reset retry count
      await this.enqueue(chunk.sessionId, chunk.chunkNumber, 0);
    }

    this.emit('retry-all', { sessionId, count: failedChunks.length });
  }

  /**
   * Event system: Register event listener
   * @param {string} event - Event name
   * @param {Function} handler - Event handler
   */
  on(event, handler) {
    if (!this.eventListeners.has(event)) {
      this.eventListeners.set(event, new Set());
    }
    this.eventListeners.get(event).add(handler);
  }

  /**
   * Event system: Unregister event listener
   * @param {string} event - Event name
   * @param {Function} handler - Event handler
   */
  off(event, handler) {
    if (this.eventListeners.has(event)) {
      this.eventListeners.get(event).delete(handler);
    }
  }

  /**
   * Event system: Emit event
   * @param {string} event - Event name
   * @param {*} data - Event data
   * @private
   */
  emit(event, data) {
    if (this.eventListeners.has(event)) {
      this.eventListeners.get(event).forEach(handler => {
        try {
          handler(data);
        } catch (error) {
          console.error(`[UploadQueue] Error in event handler for ${event}:`, error);
        }
      });
    }
  }

  /**
   * Clean up resources
   */
  destroy() {
    console.log('[UploadQueue] Destroying queue');

    // Stop processing
    this.stop();

    // Clear all retry timers
    this.retryTimers.forEach(timer => clearTimeout(timer));
    this.retryTimers.clear();

    // Abort all active uploads
    this.active.forEach(upload => {
      upload.controller.abort();
    });
    this.active.clear();

    // Clear queue
    this.queue = [];

    // Clear event listeners
    this.eventListeners.clear();
  }
}

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
  module.exports = UploadQueue;
}
