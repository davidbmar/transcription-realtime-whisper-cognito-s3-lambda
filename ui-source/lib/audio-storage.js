/**
 * Audio Storage - IndexedDB Persistence Layer
 * Version: 6.7.0 (2025-11-18)
 *
 * Purpose: Persist audio chunks locally to prevent data loss during:
 * - Screen lock / app backgrounding
 * - Network failures
 * - Page reloads
 * - Browser crashes
 *
 * NEW in v6.7.0: Chunk Size Validation
 * - Rejects chunks < 1KB (likely corrupted from browser sleep)
 * - Prevents uploading invalid WebM files to S3
 * - See saveChunk() method for implementation (lines 164-172)
 *
 * Database Schema:
 * - audio_chunks: Stores audio blob data and upload status
 * - sessions: Tracks recording session metadata
 *
 * USAGE EXAMPLE:
 *
 * // 1. Initialize the storage
 * const storage = new AudioStorage();
 * await storage.init();
 *
 * // 2. Create a recording session
 * await storage.createSession({
 *   sessionId: 'session-123',
 *   userId: 'user-456'
 * });
 *
 * // 3. Save audio chunks as they're recorded
 * await storage.saveChunk({
 *   sessionId: 'session-123',
 *   chunkNumber: 1,
 *   audioBlob: blob,
 *   mimeType: 'audio/webm',
 *   duration: 5000
 * });
 *
 * // 4. Get chunks that need uploading
 * const pendingChunks = await storage.getAllPendingChunks('session-123');
 *
 * // 5. Update chunk status after upload
 * await storage.updateChunkStatus('session-123', 1, {
 *   uploadStatus: 'uploaded',
 *   s3Key: 'audio-sessions/user-456/session-123/chunk-001.webm'
 * });
 *
 * // 6. Handle upload failures with retry
 * try {
 *   // Upload attempt...
 * } catch (error) {
 *   await storage.updateChunkStatus('session-123', 1, {
 *     uploadStatus: 'failed',
 *     lastError: error.message
 *   });
 * }
 *
 * // 7. Recovery after page reload
 * const failedChunks = await storage.getFailedChunks();
 * for (const chunk of failedChunks) {
 *   // Retry upload...
 * }
 *
 * // 8. Get storage statistics
 * const stats = await storage.getStorageStats();
 * console.log(`Total chunks: ${stats.totalChunks}`);
 * console.log(`Storage used: ${stats.totalSizeMB} MB`);
 * console.log(`Upload success rate: ${stats.uploadSuccessRate}`);
 *
 * // 9. Clean up old sessions
 * await storage.deleteOldSessions(7); // Delete sessions older than 7 days
 *
 * // 10. Close connection when done
 * storage.close();
 */

class AudioStorage {
  constructor(dbName = 'CloudDriveAudioDB', version = 1) {
    this.dbName = dbName;
    this.version = version;
    this.db = null;
  }

  /**
   * Initialize the IndexedDB database
   * Creates object stores and indexes if they don't exist
   * @returns {Promise<IDBDatabase>}
   */
  async init() {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(this.dbName, this.version);

      request.onerror = () => {
        console.error('[AudioStorage] Database open error:', request.error);
        reject(new Error(`Failed to open database: ${request.error}`));
      };

      request.onsuccess = () => {
        this.db = request.result;
        console.log('[AudioStorage] Database opened successfully');
        resolve(this.db);
      };

      request.onupgradeneeded = (event) => {
        const db = event.target.result;
        console.log('[AudioStorage] Upgrading database schema...');

        // Create audio_chunks object store
        if (!db.objectStoreNames.contains('audio_chunks')) {
          const chunksStore = db.createObjectStore('audio_chunks', {
            keyPath: ['sessionId', 'chunkNumber']
          });

          // Indexes for efficient queries
          chunksStore.createIndex('sessionId', 'sessionId', { unique: false });
          chunksStore.createIndex('uploadStatus', 'uploadStatus', { unique: false });
          chunksStore.createIndex('sessionId_uploadStatus', ['sessionId', 'uploadStatus'], { unique: false });
          chunksStore.createIndex('recordedAt', 'recordedAt', { unique: false });

          console.log('[AudioStorage] Created audio_chunks object store');
        }

        // Create sessions object store
        if (!db.objectStoreNames.contains('sessions')) {
          const sessionsStore = db.createObjectStore('sessions', {
            keyPath: 'sessionId'
          });

          // Indexes for session queries
          sessionsStore.createIndex('userId', 'userId', { unique: false });
          sessionsStore.createIndex('status', 'status', { unique: false });
          sessionsStore.createIndex('createdAt', 'createdAt', { unique: false });

          console.log('[AudioStorage] Created sessions object store');
        }
      };
    });
  }

  /**
   * Save an audio chunk to IndexedDB
   * @param {Object} chunkData - Chunk data to save
   * @param {string} chunkData.sessionId - Recording session ID
   * @param {number} chunkData.chunkNumber - Sequential chunk number
   * @param {Blob} chunkData.audioBlob - Audio data blob
   * @param {string} chunkData.mimeType - Audio MIME type (e.g., 'audio/webm')
   * @param {number} chunkData.duration - Duration in milliseconds
   * @returns {Promise<void>}
   */
  async saveChunk(chunkData) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    const {
      sessionId,
      chunkNumber,
      audioBlob,
      mimeType,
      duration = 0
    } = chunkData;

    // Validate required fields
    if (!sessionId || chunkNumber === undefined || !audioBlob) {
      throw new Error('[AudioStorage] Missing required fields: sessionId, chunkNumber, audioBlob');
    }

    // Validate chunk size - reject suspiciously small chunks
    // WebM header alone is ~50-110 bytes, so anything under 1KB is likely corrupted
    // This happens when browser goes to sleep during recording
    const MIN_CHUNK_SIZE = 1000; // 1KB minimum
    if (audioBlob.size < MIN_CHUNK_SIZE) {
      const error = new Error(`[AudioStorage] Chunk ${chunkNumber} too small (${audioBlob.size} bytes < ${MIN_CHUNK_SIZE} bytes). Likely corrupted due to browser sleep/backgrounding. Skipping.`);
      console.warn(error.message);
      throw error;
    }

    const chunk = {
      sessionId,
      chunkNumber,
      audioBlob,
      mimeType: mimeType || audioBlob.type || 'audio/webm',
      size: audioBlob.size,
      duration,
      recordedAt: new Date().toISOString(),

      // Upload tracking
      uploadStatus: 'pending',
      uploadAttempts: 0,
      lastUploadAttempt: null,
      lastError: null,
      s3Key: null,
      uploadedAt: null
    };

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readwrite');
      const store = transaction.objectStore('audio_chunks');
      const request = store.put(chunk);

      request.onsuccess = () => {
        console.log(`[AudioStorage] Saved chunk ${chunkNumber} for session ${sessionId} (${audioBlob.size} bytes)`);
        resolve();
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to save chunk ${chunkNumber}:`, request.error);
        reject(new Error(`Failed to save chunk: ${request.error}`));
      };
    });
  }

  /**
   * Get a specific audio chunk
   * @param {string} sessionId - Session ID
   * @param {number} chunkNumber - Chunk number
   * @returns {Promise<Object|null>} Chunk data or null if not found
   */
  async getChunk(sessionId, chunkNumber) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readonly');
      const store = transaction.objectStore('audio_chunks');
      const request = store.get([sessionId, chunkNumber]);

      request.onsuccess = () => {
        resolve(request.result || null);
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to get chunk ${chunkNumber}:`, request.error);
        reject(new Error(`Failed to get chunk: ${request.error}`));
      };
    });
  }

  /**
   * Get all chunks for a session
   * @param {string} sessionId - Session ID
   * @returns {Promise<Array>} Array of chunk objects
   */
  async getSessionChunks(sessionId) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readonly');
      const store = transaction.objectStore('audio_chunks');
      const index = store.index('sessionId');
      const request = index.getAll(sessionId);

      request.onsuccess = () => {
        const chunks = request.result || [];
        // Sort by chunk number
        chunks.sort((a, b) => a.chunkNumber - b.chunkNumber);
        resolve(chunks);
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to get session chunks:`, request.error);
        reject(new Error(`Failed to get session chunks: ${request.error}`));
      };
    });
  }

  /**
   * Get all pending chunks (not uploaded) for a session
   * @param {string} sessionId - Session ID (optional - if not provided, gets all pending chunks)
   * @returns {Promise<Array>} Array of pending chunk objects
   */
  async getAllPendingChunks(sessionId = null) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readonly');
      const store = transaction.objectStore('audio_chunks');

      let request;
      if (sessionId) {
        const index = store.index('sessionId_uploadStatus');
        request = index.getAll([sessionId, 'pending']);
      } else {
        const index = store.index('uploadStatus');
        request = index.getAll('pending');
      }

      request.onsuccess = () => {
        const chunks = request.result || [];
        // Sort by session and chunk number
        chunks.sort((a, b) => {
          if (a.sessionId !== b.sessionId) {
            return a.sessionId.localeCompare(b.sessionId);
          }
          return a.chunkNumber - b.chunkNumber;
        });
        resolve(chunks);
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to get pending chunks:`, request.error);
        reject(new Error(`Failed to get pending chunks: ${request.error}`));
      };
    });
  }

  /**
   * Get all failed chunks for retry
   * @param {string} sessionId - Session ID (optional)
   * @returns {Promise<Array>} Array of failed chunk objects
   */
  async getFailedChunks(sessionId = null) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readonly');
      const store = transaction.objectStore('audio_chunks');

      let request;
      if (sessionId) {
        const index = store.index('sessionId_uploadStatus');
        request = index.getAll([sessionId, 'failed']);
      } else {
        const index = store.index('uploadStatus');
        request = index.getAll('failed');
      }

      request.onsuccess = () => {
        const chunks = request.result || [];
        chunks.sort((a, b) => {
          if (a.sessionId !== b.sessionId) {
            return a.sessionId.localeCompare(b.sessionId);
          }
          return a.chunkNumber - b.chunkNumber;
        });
        resolve(chunks);
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to get failed chunks:`, request.error);
        reject(new Error(`Failed to get failed chunks: ${request.error}`));
      };
    });
  }

  /**
   * Update chunk upload status
   * @param {string} sessionId - Session ID
   * @param {number} chunkNumber - Chunk number
   * @param {Object} updates - Fields to update
   * @param {string} updates.uploadStatus - New status ('pending'|'uploading'|'uploaded'|'failed')
   * @param {string} updates.s3Key - S3 object key (optional)
   * @param {string} updates.lastError - Error message (optional)
   * @returns {Promise<void>}
   */
  async updateChunkStatus(sessionId, chunkNumber, updates) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readwrite');
      const store = transaction.objectStore('audio_chunks');

      // First get the chunk
      const getRequest = store.get([sessionId, chunkNumber]);

      getRequest.onsuccess = () => {
        const chunk = getRequest.result;

        if (!chunk) {
          reject(new Error(`Chunk not found: ${sessionId}/${chunkNumber}`));
          return;
        }

        // Update fields
        if (updates.uploadStatus) {
          chunk.uploadStatus = updates.uploadStatus;
        }
        if (updates.uploadStatus === 'uploading' || updates.uploadStatus === 'failed') {
          chunk.uploadAttempts = (chunk.uploadAttempts || 0) + 1;
          chunk.lastUploadAttempt = new Date().toISOString();
        }
        if (updates.uploadStatus === 'uploaded') {
          chunk.uploadedAt = new Date().toISOString();
        }
        if (updates.s3Key) {
          chunk.s3Key = updates.s3Key;
        }
        if (updates.lastError !== undefined) {
          chunk.lastError = updates.lastError;
        }

        // Save updated chunk
        const putRequest = store.put(chunk);

        putRequest.onsuccess = () => {
          console.log(`[AudioStorage] Updated chunk ${chunkNumber} status to ${chunk.uploadStatus}`);
          resolve();
        };

        putRequest.onerror = () => {
          console.error(`[AudioStorage] Failed to update chunk status:`, putRequest.error);
          reject(new Error(`Failed to update chunk status: ${putRequest.error}`));
        };
      };

      getRequest.onerror = () => {
        console.error(`[AudioStorage] Failed to get chunk for update:`, getRequest.error);
        reject(new Error(`Failed to get chunk for update: ${getRequest.error}`));
      };
    });
  }

  /**
   * Create a new recording session
   * @param {Object} sessionData - Session data
   * @param {string} sessionData.sessionId - Unique session ID
   * @param {string} sessionData.userId - User ID
   * @returns {Promise<void>}
   */
  async createSession(sessionData) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    const { sessionId, userId } = sessionData;

    if (!sessionId || !userId) {
      throw new Error('[AudioStorage] Missing required fields: sessionId, userId');
    }

    const session = {
      sessionId,
      userId,
      createdAt: new Date().toISOString(),
      status: 'recording',
      totalChunks: 0,
      uploadedChunks: 0,
      failedChunks: 0
    };

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['sessions'], 'readwrite');
      const store = transaction.objectStore('sessions');
      const request = store.put(session);

      request.onsuccess = () => {
        console.log(`[AudioStorage] Created session ${sessionId}`);
        resolve();
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to create session:`, request.error);
        reject(new Error(`Failed to create session: ${request.error}`));
      };
    });
  }

  /**
   * Update session metadata
   * @param {string} sessionId - Session ID
   * @param {Object} updates - Fields to update
   * @returns {Promise<void>}
   */
  async updateSession(sessionId, updates) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['sessions'], 'readwrite');
      const store = transaction.objectStore('sessions');

      const getRequest = store.get(sessionId);

      getRequest.onsuccess = () => {
        const session = getRequest.result;

        if (!session) {
          reject(new Error(`Session not found: ${sessionId}`));
          return;
        }

        // Update fields
        Object.assign(session, updates);

        const putRequest = store.put(session);

        putRequest.onsuccess = () => {
          console.log(`[AudioStorage] Updated session ${sessionId}`);
          resolve();
        };

        putRequest.onerror = () => {
          console.error(`[AudioStorage] Failed to update session:`, putRequest.error);
          reject(new Error(`Failed to update session: ${putRequest.error}`));
        };
      };

      getRequest.onerror = () => {
        console.error(`[AudioStorage] Failed to get session:`, getRequest.error);
        reject(new Error(`Failed to get session: ${getRequest.error}`));
      };
    });
  }

  /**
   * Get session metadata
   * @param {string} sessionId - Session ID
   * @returns {Promise<Object|null>} Session object or null
   */
  async getSession(sessionId) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['sessions'], 'readonly');
      const store = transaction.objectStore('sessions');
      const request = store.get(sessionId);

      request.onsuccess = () => {
        resolve(request.result || null);
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to get session:`, request.error);
        reject(new Error(`Failed to get session: ${request.error}`));
      };
    });
  }

  /**
   * Get all sessions
   * @param {string} userId - Filter by user ID (optional)
   * @returns {Promise<Array>} Array of session objects
   */
  async getAllSessions(userId = null) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['sessions'], 'readonly');
      const store = transaction.objectStore('sessions');

      let request;
      if (userId) {
        const index = store.index('userId');
        request = index.getAll(userId);
      } else {
        request = store.getAll();
      }

      request.onsuccess = () => {
        const sessions = request.result || [];
        // Sort by creation date (newest first)
        sessions.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
        resolve(sessions);
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to get sessions:`, request.error);
        reject(new Error(`Failed to get sessions: ${request.error}`));
      };
    });
  }

  /**
   * Delete a specific chunk
   * @param {string} sessionId - Session ID
   * @param {number} chunkNumber - Chunk number
   * @returns {Promise<void>}
   */
  async deleteChunk(sessionId, chunkNumber) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readwrite');
      const store = transaction.objectStore('audio_chunks');
      const request = store.delete([sessionId, chunkNumber]);

      request.onsuccess = () => {
        console.log(`[AudioStorage] Deleted chunk ${chunkNumber} from session ${sessionId}`);
        resolve();
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to delete chunk:`, request.error);
        reject(new Error(`Failed to delete chunk: ${request.error}`));
      };
    });
  }

  /**
   * Delete all chunks for a session
   * @param {string} sessionId - Session ID
   * @returns {Promise<number>} Number of chunks deleted
   */
  async deleteSessionChunks(sessionId) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    const chunks = await this.getSessionChunks(sessionId);

    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readwrite');
      const store = transaction.objectStore('audio_chunks');

      let deleteCount = 0;
      let errors = [];

      chunks.forEach((chunk) => {
        const request = store.delete([chunk.sessionId, chunk.chunkNumber]);

        request.onsuccess = () => {
          deleteCount++;
        };

        request.onerror = () => {
          errors.push(request.error);
        };
      });

      transaction.oncomplete = () => {
        if (errors.length > 0) {
          console.error(`[AudioStorage] Deleted ${deleteCount} chunks with ${errors.length} errors`);
        } else {
          console.log(`[AudioStorage] Deleted ${deleteCount} chunks for session ${sessionId}`);
        }
        resolve(deleteCount);
      };

      transaction.onerror = () => {
        console.error(`[AudioStorage] Transaction failed:`, transaction.error);
        reject(new Error(`Failed to delete session chunks: ${transaction.error}`));
      };
    });
  }

  /**
   * Delete a session and all its chunks
   * @param {string} sessionId - Session ID
   * @returns {Promise<void>}
   */
  async deleteSession(sessionId) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    // Delete all chunks first
    await this.deleteSessionChunks(sessionId);

    // Then delete the session
    return new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['sessions'], 'readwrite');
      const store = transaction.objectStore('sessions');
      const request = store.delete(sessionId);

      request.onsuccess = () => {
        console.log(`[AudioStorage] Deleted session ${sessionId}`);
        resolve();
      };

      request.onerror = () => {
        console.error(`[AudioStorage] Failed to delete session:`, request.error);
        reject(new Error(`Failed to delete session: ${request.error}`));
      };
    });
  }

  /**
   * Delete old completed sessions (uploaded chunks only)
   * @param {number} daysOld - Delete sessions older than this many days
   * @returns {Promise<number>} Number of sessions deleted
   */
  async deleteOldSessions(daysOld = 7) {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - daysOld);
    const cutoffISO = cutoffDate.toISOString();

    const allSessions = await this.getAllSessions();
    const oldSessions = allSessions.filter(session => {
      // Only delete completed sessions older than cutoff
      return session.status === 'completed' && session.createdAt < cutoffISO;
    });

    let deleteCount = 0;
    for (const session of oldSessions) {
      try {
        await this.deleteSession(session.sessionId);
        deleteCount++;
      } catch (error) {
        console.error(`[AudioStorage] Failed to delete old session ${session.sessionId}:`, error);
      }
    }

    console.log(`[AudioStorage] Deleted ${deleteCount} old sessions (>${daysOld} days)`);
    return deleteCount;
  }

  /**
   * Get storage usage statistics
   * @returns {Promise<Object>} Storage stats
   */
  async getStorageStats() {
    if (!this.db) {
      throw new Error('[AudioStorage] Database not initialized. Call init() first.');
    }

    const sessions = await this.getAllSessions();
    const chunks = await new Promise((resolve, reject) => {
      const transaction = this.db.transaction(['audio_chunks'], 'readonly');
      const store = transaction.objectStore('audio_chunks');
      const request = store.getAll();

      request.onsuccess = () => resolve(request.result || []);
      request.onerror = () => reject(new Error('Failed to get chunks'));
    });

    const totalSize = chunks.reduce((sum, chunk) => sum + (chunk.size || 0), 0);
    const uploadedChunks = chunks.filter(c => c.uploadStatus === 'uploaded').length;
    const pendingChunks = chunks.filter(c => c.uploadStatus === 'pending').length;
    const failedChunks = chunks.filter(c => c.uploadStatus === 'failed').length;
    const uploadingChunks = chunks.filter(c => c.uploadStatus === 'uploading').length;

    return {
      totalSessions: sessions.length,
      totalChunks: chunks.length,
      totalSizeBytes: totalSize,
      totalSizeMB: (totalSize / 1024 / 1024).toFixed(2),
      uploadedChunks,
      pendingChunks,
      failedChunks,
      uploadingChunks,
      uploadSuccessRate: chunks.length > 0
        ? ((uploadedChunks / chunks.length) * 100).toFixed(1) + '%'
        : 'N/A'
    };
  }

  /**
   * Close the database connection
   */
  close() {
    if (this.db) {
      this.db.close();
      this.db = null;
      console.log('[AudioStorage] Database closed');
    }
  }
}

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
  module.exports = AudioStorage;
}
