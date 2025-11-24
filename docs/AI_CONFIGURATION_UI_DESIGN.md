# AI Configuration UI - Design Proposal (Updated)

**Version**: 2.0
**Date**: 2025-11-24
**Status**: Ready for Implementation

## Overview

This design enables users to customize each AI insight category (Highlights, Action Items, Key Terms, Key Themes, Topic Changes) by clicking on a timeline tab to reveal its configuration in the left sidebar. Users can rename tabs, edit prompts, adjust settings, and re-run analysis for individual categories.

## Current Implementation (Completed)

### ✅ Phase 1: Basic AI Timeline (DONE)
- [x] Interactive timeline with colored markers
- [x] 6 navigation tabs (All, Highlights, Action Items, Key Terms, Themes, Topic Changes)
- [x] Click-to-jump functionality from markers to transcript
- [x] Hover tooltips showing time and summary
- [x] Sticky positioning for timeline navigation
- [x] Session switching with proper state reset
- [x] Cost-effective analysis (~$0.002/transcript using Claude Haiku)

### Backend Components (DONE)
- [x] `scripts/lib/ai-analysis.py` - Claude API integration
- [x] `scripts/525-generate-ai-analysis.sh` - Bash wrapper
- [x] `scripts/527-find-session-path.sh` - Interactive session finder
- [x] S3 storage: `transcription-ai-analysis.json`
- [x] Virtual environment: `venv-ai-analysis/`

### Frontend Components (DONE)
- [x] `AITimelineNavigator` class with `reset()` method
- [x] Timeline rendering with color-coded markers
- [x] Tab filtering and count badges
- [x] Paragraph highlighting and audio seeking

## Phase 2: Per-Tab Configuration UI (Proposed)

### 1. UI Mockup - Left Sidebar Transformation

#### Before (Default State):
```
┌─────────────────────────┐
│ CloudDrive Logo         │
│                         │
│ [Session Info]          │
│ • Duration: 45:23       │
│ • Date: Nov 23, 2025   │
│ • Chunks: 3             │
│                         │
│ [Controls]              │
│ ▶ Play Audio            │
│ ⬇ Download Transcript   │
│ 📋 Export Options       │
│                         │
└─────────────────────────┘
```

#### After (Tab Selected - "Highlights"):
```
┌─────────────────────────┐
│ ⬅ Back to Session Info  │
│                         │
│ ✨ AI Category Config   │
│ ━━━━━━━━━━━━━━━━━━━━━━━ │
│                         │
│ Tab Name:               │
│ ┌─────────────────────┐ │
│ │ Highlights        ✎ │ │
│ └─────────────────────┘ │
│ (e.g., "Key Questions") │
│                         │
│ Prompt Template:        │
│ ┌─────────────────────┐ │
│ │ Extract 8-15 most  │ │
│ │ significant moments│ │
│ │ or key insights... │ │
│ │                    │ │
│ │ [▼ Expand Full]    │ │
│ └─────────────────────┘ │
│                         │
│ Settings:               │
│ • Model: claude-haiku   │
│ • Max Items: 15         │
│ • Min Importance: 0.7   │
│                         │
│ Status:                 │
│ ✓ Last analyzed: 2m ago │
│ 💰 Cost: $0.0008        │
│ 📊 Current: 12 items    │
│                         │
│ ┌─────────────────────┐ │
│ │  🔄 Re-analyze Only │ │
│ │     This Category   │ │
│ └─────────────────────┘ │
│                         │
│ ┌─────────────────────┐ │
│ │ 💾 Save Config      │ │
│ └─────────────────────┘ │
│                         │
│ [Reset to Default]      │
│                         │
└─────────────────────────┘
```

### 2. Data Structure - Enhanced JSON Schema

#### Configuration Storage Location:
**S3 Path**: `users/{userId}/audio/sessions/{sessionId}/ai-config.json`

#### Schema:
```json
{
  "version": "2.0",
  "sessionId": "session_2025-11-24T10_30_00_000Z",
  "lastModified": "2025-11-24T10:30:00Z",
  "categories": {
    "highlights": {
      "displayName": "Highlights",
      "enabled": true,
      "prompt": "Extract 8-15 most significant moments or key insights...\n\nIMPORTANT RULES:\n- All time codes must be in SECONDS as float\n- Return ONLY valid JSON\n- Include importance scores (0.0 to 1.0)\n- Categories: [\"insight\", \"prediction\", \"quote\", \"decision\", \"conclusion\"]",
      "settings": {
        "model": "claude-3-5-haiku-20241022",
        "maxTokens": 8000,
        "maxItems": 15,
        "minImportance": 0.7,
        "temperature": 0.0
      },
      "metadata": {
        "lastAnalyzed": "2025-11-24T10:28:00Z",
        "itemCount": 12,
        "tokensUsed": 3200,
        "costUSD": 0.0008
      }
    },
    "actionItems": {
      "displayName": "Action Items",
      "enabled": true,
      "prompt": "Find 5-10 explicit tasks, recommendations, or actionable steps mentioned...",
      "settings": {
        "model": "claude-3-5-haiku-20241022",
        "maxTokens": 8000,
        "maxItems": 10,
        "minPriority": "medium",
        "includeSuggestions": true
      },
      "metadata": {
        "lastAnalyzed": "2025-11-24T10:28:00Z",
        "itemCount": 5,
        "tokensUsed": 2800,
        "costUSD": 0.0007
      }
    },
    "keyTerms": {
      "displayName": "Technical Terms",
      "enabled": true,
      "prompt": "Identify 8-15 technical terms, domain-specific vocabulary...",
      "settings": {
        "model": "claude-3-5-haiku-20241022",
        "maxTokens": 8000,
        "maxItems": 15,
        "firstMentionOnly": true
      },
      "metadata": {
        "lastAnalyzed": "2025-11-24T10:28:00Z",
        "itemCount": 14,
        "tokensUsed": 3000,
        "costUSD": 0.0008
      }
    },
    "keyThemes": {
      "displayName": "Themes",
      "enabled": true,
      "prompt": "Identify 4-8 main topics or subjects discussed at length...",
      "settings": {
        "model": "claude-3-5-haiku-20241022",
        "maxTokens": 8000,
        "maxItems": 8,
        "minIntensity": 0.5,
        "minDuration": 30
      },
      "metadata": {
        "lastAnalyzed": "2025-11-24T10:28:00Z",
        "itemCount": 6,
        "tokensUsed": 2900,
        "costUSD": 0.0007
      }
    },
    "topicChanges": {
      "displayName": "Topic Changes",
      "enabled": true,
      "prompt": "Find 6-12 points where speaker shifts to a new distinct subject...",
      "settings": {
        "model": "claude-3-5-haiku-20241022",
        "maxTokens": 8000,
        "maxItems": 12,
        "includeImplicit": true
      },
      "metadata": {
        "lastAnalyzed": "2025-11-24T10:28:00Z",
        "itemCount": 8,
        "tokensUsed": 2700,
        "costUSD": 0.0007
      }
    }
  },
  "_meta": {
    "totalCost": 0.0045,
    "totalTokens": 14600,
    "costByCategory": {
      "highlights": 0.0008,
      "actionItems": 0.0007,
      "keyTerms": 0.0008,
      "keyThemes": 0.0007,
      "topicChanges": 0.0007
    }
  }
}
```

#### Default Prompts Library:
**Location**: `scripts/lib/ai-prompts.json`

```json
{
  "version": "1.0",
  "templates": {
    "highlights": {
      "displayName": "Highlights",
      "prompt": "Extract 8-15 most significant moments or key insights from this transcript.\n\nFor each highlight include:\n- Time codes (in seconds as float)\n- Summary of the insight (1-2 sentences)\n- Importance score (0.0 to 1.0)\n- Categories: [\"insight\", \"prediction\", \"quote\", \"decision\", \"conclusion\"]\n\nReturn format:\n{\n  \"results\": [\n    {\n      \"timeCodeStart\": 180.0,\n      \"timeCodeEnd\": 195.0,\n      \"summary\": \"Key insight about...\",\n      \"importance\": 0.95,\n      \"categories\": [\"insight\", \"prediction\"]\n    }\n  ]\n}",
      "settings": {
        "maxItems": 15,
        "minImportance": 0.7,
        "temperature": 0.0
      }
    },
    "actionItems": {
      "displayName": "Action Items",
      "prompt": "Find 5-10 explicit tasks, recommendations, or actionable steps mentioned in this transcript.\n\nFor each action item include:\n- Time codes (in seconds as float)\n- Brief summary (1 sentence)\n- Extract exact quote\n- Priority: \"high\", \"medium\", or \"low\"\n\nCast a wide net - include suggestions, proposals, calls to action.\n\nReturn format:\n{\n  \"results\": [\n    {\n      \"timeCodeStart\": 59.0,\n      \"timeCodeEnd\": 68.5,\n      \"summary\": \"Focus on evolutionary optimization\",\n      \"text\": \"We need to shift our approach to evolutionary algorithms\",\n      \"priority\": \"high\"\n    }\n  ]\n}",
      "settings": {
        "maxItems": 10,
        "minPriority": "medium",
        "includeSuggestions": true
      }
    },
    "keyTerms": {
      "displayName": "Key Terms",
      "prompt": "Identify 8-15 technical terms, domain-specific vocabulary, or important concepts mentioned in this transcript.\n\nFor each term include:\n- First mention only (don't repeat same term)\n- Time codes (in seconds as float)\n- Brief definition or context\n- Mark as firstMention: true\n\nInclude jargon, acronyms, specialized terminology.\n\nReturn format:\n{\n  \"results\": [\n    {\n      \"timeCodeStart\": 47.0,\n      \"timeCodeEnd\": 51.0,\n      \"term\": \"Reinforcement Learning\",\n      \"definition\": \"ML technique using rewards and penalties\",\n      \"context\": \"Discussion of AI training methodologies\",\n      \"firstMention\": true\n    }\n  ]\n}",
      "settings": {
        "maxItems": 15,
        "firstMentionOnly": true
      }
    },
    "keyThemes": {
      "displayName": "Key Themes",
      "prompt": "Identify 4-8 main topics or subjects discussed at length in this transcript.\n\nFor each theme include:\n- Time ranges where theme is actively discussed (start and end)\n- Brief summary (2 sentences max)\n- Intensity score (0.0 to 1.0 based on depth/importance)\n\nInclude both major and minor themes.\n\nReturn format:\n{\n  \"results\": [\n    {\n      \"timeCodeStart\": 120.0,\n      \"timeCodeEnd\": 245.0,\n      \"theme\": \"Evolution vs Traditional Programming\",\n      \"summary\": \"Extended comparison of evolutionary algorithms versus conventional software development approaches\",\n      \"intensity\": 0.89\n    }\n  ]\n}",
      "settings": {
        "maxItems": 8,
        "minIntensity": 0.5,
        "minDuration": 30
      }
    },
    "topicChanges": {
      "displayName": "Topic Changes",
      "prompt": "Find 6-12 points where the speaker shifts to a new distinct subject.\n\nFor each transition include:\n- Exact time code of transition\n- What changed from/to\n- Type: \"explicit\" (announced) or \"implicit\" (natural shift)\n\nBe sensitive to subtle transitions, not just major shifts.\n\nReturn format:\n{\n  \"results\": [\n    {\n      \"timeCode\": 32.5,\n      \"fromTopic\": \"Introduction\",\n      \"toTopic\": \"AI Development Timeline\",\n      \"transitionType\": \"explicit\"\n    }\n  ]\n}",
      "settings": {
        "maxItems": 12,
        "includeImplicit": true
      }
    }
  },
  "presets": {
    "interview": {
      "highlights": {
        "displayName": "Key Interviewer Questions",
        "prompt": "Extract the most important questions asked by the interviewer..."
      },
      "actionItems": {
        "displayName": "Follow-up Tasks",
        "prompt": "Find all follow-up tasks or commitments made..."
      }
    },
    "meeting": {
      "highlights": {
        "displayName": "Key Decisions",
        "prompt": "Extract all decisions made during the meeting..."
      },
      "actionItems": {
        "displayName": "Team Assignments",
        "prompt": "Find all tasks assigned to team members..."
      }
    },
    "lecture": {
      "highlights": {
        "displayName": "Key Concepts",
        "prompt": "Extract main concepts taught in the lecture..."
      },
      "keyTerms": {
        "displayName": "Technical Vocabulary",
        "prompt": "Identify all technical terms introduced..."
      }
    }
  }
}
```

### 3. Component Architecture

#### Frontend Components (New)

**File**: `cognito-stack/web/transcript-editor-v2.html`

##### 3.1. `AIConfigPanel` Class

```javascript
class AIConfigPanel {
    constructor() {
        this.currentCategory = null;
        this.config = null;
        this.defaultPrompts = null;
        this.isDirty = false;
        this.originalValues = {};
    }

    async init() {
        await this.loadConfig();
        await this.loadDefaultPrompts();
        this.attachEventListeners();
    }

    async loadConfig() {
        // Try to load custom config from S3
        const userId = getUserId();
        const sessionFolder = currentSession.folder;
        const sessionPath = `users/${userId}/audio/sessions/${sessionFolder}`;
        const configKey = `${sessionPath}/ai-config.json`;

        try {
            const downloadData = await apiCall(`/api/s3/download/${encodeURIComponent(configKey)}`);
            const response = await fetch(downloadData.downloadUrl);

            if (response.ok) {
                this.config = await response.json();
                console.log('✅ Loaded custom AI config');
                return;
            }
        } catch (error) {
            console.log('No custom config found, using defaults');
        }

        // Fall back to defaults
        await this.loadDefaultConfig();
    }

    async loadDefaultConfig() {
        // Initialize with default structure
        this.config = {
            version: "2.0",
            sessionId: currentSession.folder,
            lastModified: new Date().toISOString(),
            categories: {},
            _meta: {
                totalCost: 0,
                totalTokens: 0,
                costByCategory: {}
            }
        };

        // Populate from default prompts
        if (this.defaultPrompts) {
            Object.keys(this.defaultPrompts.templates).forEach(category => {
                const template = this.defaultPrompts.templates[category];
                this.config.categories[category] = {
                    displayName: template.displayName,
                    enabled: true,
                    prompt: template.prompt,
                    settings: {
                        model: "claude-3-5-haiku-20241022",
                        maxTokens: 8000,
                        ...template.settings
                    },
                    metadata: {
                        lastAnalyzed: null,
                        itemCount: 0,
                        tokensUsed: 0,
                        costUSD: 0
                    }
                };
            });
        }
    }

    async loadDefaultPrompts() {
        // Load from embedded JSON or fetch from S3
        const response = await fetch('/ai-prompts.json');
        if (response.ok) {
            this.defaultPrompts = await response.json();
        }
    }

    showCategory(categoryId) {
        this.currentCategory = categoryId;

        // Hide session info, show config panel
        document.getElementById('session-info').style.display = 'none';
        document.getElementById('ai-config-panel').style.display = 'block';

        this.render();
    }

    close() {
        // Show session info, hide config panel
        document.getElementById('session-info').style.display = 'block';
        document.getElementById('ai-config-panel').style.display = 'none';

        this.currentCategory = null;

        // Warn if unsaved changes
        if (this.isDirty) {
            if (!confirm('You have unsaved changes. Are you sure you want to close?')) {
                return;
            }
            this.isDirty = false;
        }
    }

    render() {
        if (!this.currentCategory) return;

        const categoryConfig = this.config.categories[this.currentCategory];
        if (!categoryConfig) return;

        // Update category name input
        document.getElementById('category-name').value = categoryConfig.displayName;

        // Update prompt editor
        document.getElementById('category-prompt').value = categoryConfig.prompt;

        // Update settings
        document.getElementById('setting-model').value = categoryConfig.settings.model;
        document.getElementById('setting-max-items').value = categoryConfig.settings.maxItems || 15;

        // Render category-specific settings
        this.renderCategorySpecificSettings(this.currentCategory, categoryConfig.settings);

        // Update status
        const metadata = categoryConfig.metadata;
        document.getElementById('last-analyzed-time').textContent =
            metadata.lastAnalyzed ? this.formatRelativeTime(metadata.lastAnalyzed) : 'Never';
        document.getElementById('estimated-cost').textContent =
            `$${(metadata.costUSD || 0).toFixed(4)}`;
        document.getElementById('current-count').textContent =
            `${metadata.itemCount || 0} items`;

        // Store original values for dirty detection
        this.originalValues = {
            displayName: categoryConfig.displayName,
            prompt: categoryConfig.prompt,
            settings: JSON.stringify(categoryConfig.settings)
        };

        this.isDirty = false;
        this.updateSaveButton();
    }

    renderCategorySpecificSettings(category, settings) {
        const container = document.getElementById('category-specific-settings');
        container.innerHTML = '';

        // Render settings specific to each category
        switch(category) {
            case 'highlights':
                container.innerHTML = `
                    <div class="setting-item">
                        <label for="setting-min-importance">Min Importance:</label>
                        <input type="number" id="setting-min-importance"
                               min="0" max="1" step="0.1"
                               value="${settings.minImportance || 0.7}">
                    </div>
                `;
                break;
            case 'actionItems':
                container.innerHTML = `
                    <div class="setting-item">
                        <label for="setting-min-priority">Min Priority:</label>
                        <select id="setting-min-priority">
                            <option value="low" ${settings.minPriority === 'low' ? 'selected' : ''}>Low</option>
                            <option value="medium" ${settings.minPriority === 'medium' ? 'selected' : ''}>Medium</option>
                            <option value="high" ${settings.minPriority === 'high' ? 'selected' : ''}>High</option>
                        </select>
                    </div>
                    <div class="setting-item">
                        <label for="setting-include-suggestions">
                            <input type="checkbox" id="setting-include-suggestions"
                                   ${settings.includeSuggestions ? 'checked' : ''}>
                            Include Suggestions
                        </label>
                    </div>
                `;
                break;
            case 'keyTerms':
                container.innerHTML = `
                    <div class="setting-item">
                        <label for="setting-first-mention-only">
                            <input type="checkbox" id="setting-first-mention-only"
                                   ${settings.firstMentionOnly !== false ? 'checked' : ''}>
                            First Mention Only
                        </label>
                    </div>
                `;
                break;
            case 'keyThemes':
                container.innerHTML = `
                    <div class="setting-item">
                        <label for="setting-min-intensity">Min Intensity:</label>
                        <input type="number" id="setting-min-intensity"
                               min="0" max="1" step="0.1"
                               value="${settings.minIntensity || 0.5}">
                    </div>
                    <div class="setting-item">
                        <label for="setting-min-duration">Min Duration (seconds):</label>
                        <input type="number" id="setting-min-duration"
                               min="0" step="5"
                               value="${settings.minDuration || 30}">
                    </div>
                `;
                break;
            case 'topicChanges':
                container.innerHTML = `
                    <div class="setting-item">
                        <label for="setting-include-implicit">
                            <input type="checkbox" id="setting-include-implicit"
                                   ${settings.includeImplicit !== false ? 'checked' : ''}>
                            Include Implicit Transitions
                        </label>
                    </div>
                `;
                break;
        }
    }

    attachEventListeners() {
        // Detect changes
        document.getElementById('category-name').addEventListener('input', () => {
            this.markDirty();
        });

        document.getElementById('category-prompt').addEventListener('input', () => {
            this.markDirty();
        });

        document.getElementById('setting-model').addEventListener('change', () => {
            this.markDirty();
        });

        document.getElementById('setting-max-items').addEventListener('input', () => {
            this.markDirty();
        });

        // Re-render category-specific settings when they change
        document.addEventListener('change', (e) => {
            if (e.target.id.startsWith('setting-')) {
                this.markDirty();
            }
        });
    }

    markDirty() {
        this.isDirty = true;
        this.updateSaveButton();
    }

    updateSaveButton() {
        const saveBtn = document.querySelector('.btn-save');
        if (this.isDirty) {
            saveBtn.disabled = false;
            saveBtn.classList.add('dirty');
        } else {
            saveBtn.disabled = true;
            saveBtn.classList.remove('dirty');
        }
    }

    async saveConfig() {
        if (!this.currentCategory) return;

        // Collect current values
        const categoryConfig = this.config.categories[this.currentCategory];

        categoryConfig.displayName = document.getElementById('category-name').value;
        categoryConfig.prompt = document.getElementById('category-prompt').value;
        categoryConfig.settings.model = document.getElementById('setting-model').value;
        categoryConfig.settings.maxItems = parseInt(document.getElementById('setting-max-items').value);

        // Collect category-specific settings
        this.collectCategorySpecificSettings(this.currentCategory, categoryConfig.settings);

        // Update config metadata
        this.config.lastModified = new Date().toISOString();

        // Save to S3
        const userId = getUserId();
        const sessionFolder = currentSession.folder;
        const sessionPath = `users/${userId}/audio/sessions/${sessionFolder}`;
        const configKey = `${sessionPath}/ai-config.json`;

        try {
            // Upload config
            const uploadData = await apiCall(`/api/s3/upload/${encodeURIComponent(configKey)}`);
            const uploadResponse = await fetch(uploadData.uploadUrl, {
                method: 'PUT',
                body: JSON.stringify(this.config, null, 2),
                headers: {
                    'Content-Type': 'application/json'
                }
            });

            if (uploadResponse.ok) {
                showToast('Configuration saved', 'success');
                this.isDirty = false;
                this.updateSaveButton();
            } else {
                throw new Error('Upload failed');
            }
        } catch (error) {
            console.error('Error saving config:', error);
            showToast('Failed to save configuration', 'error');
        }
    }

    collectCategorySpecificSettings(category, settings) {
        switch(category) {
            case 'highlights':
                settings.minImportance = parseFloat(document.getElementById('setting-min-importance').value);
                break;
            case 'actionItems':
                settings.minPriority = document.getElementById('setting-min-priority').value;
                settings.includeSuggestions = document.getElementById('setting-include-suggestions').checked;
                break;
            case 'keyTerms':
                settings.firstMentionOnly = document.getElementById('setting-first-mention-only').checked;
                break;
            case 'keyThemes':
                settings.minIntensity = parseFloat(document.getElementById('setting-min-intensity').value);
                settings.minDuration = parseInt(document.getElementById('setting-min-duration').value);
                break;
            case 'topicChanges':
                settings.includeImplicit = document.getElementById('setting-include-implicit').checked;
                break;
        }
    }

    async reanalyzeCategory() {
        if (!this.currentCategory) return;

        // Warn if unsaved changes
        if (this.isDirty) {
            if (!confirm('Save configuration before re-analyzing?')) {
                return;
            }
            await this.saveConfig();
        }

        // Show progress
        document.getElementById('reanalysis-progress').style.display = 'block';
        document.querySelector('.btn-reanalyze').disabled = true;

        const categoryConfig = this.config.categories[this.currentCategory];

        try {
            // Call backend API to re-analyze this category
            const response = await apiCall('/api/ai/reanalyze', {
                method: 'POST',
                body: JSON.stringify({
                    sessionPath: `users/${getUserId()}/audio/sessions/${currentSession.folder}`,
                    category: this.currentCategory,
                    prompt: categoryConfig.prompt,
                    settings: categoryConfig.settings
                })
            });

            // Update metadata
            categoryConfig.metadata = {
                lastAnalyzed: new Date().toISOString(),
                itemCount: response.count,
                tokensUsed: response.tokens,
                costUSD: response.cost
            };

            // Update display
            this.render();

            // Reload AI timeline
            await aiNavigator.loadAnalysis();
            aiNavigator.render();

            showToast(`Re-analyzed ${this.currentCategory}: ${response.count} items, $${response.cost.toFixed(4)}`, 'success');

        } catch (error) {
            console.error('Error re-analyzing category:', error);
            showToast('Failed to re-analyze category', 'error');
        } finally {
            document.getElementById('reanalysis-progress').style.display = 'none';
            document.querySelector('.btn-reanalyze').disabled = false;
        }
    }

    resetToDefault() {
        if (!this.currentCategory || !this.defaultPrompts) return;

        if (!confirm('Reset this category to default settings?')) {
            return;
        }

        const template = this.defaultPrompts.templates[this.currentCategory];
        if (template) {
            const categoryConfig = this.config.categories[this.currentCategory];
            categoryConfig.displayName = template.displayName;
            categoryConfig.prompt = template.prompt;
            categoryConfig.settings = {
                model: "claude-3-5-haiku-20241022",
                maxTokens: 8000,
                ...template.settings
            };

            this.render();
            this.markDirty();
        }
    }

    formatRelativeTime(isoString) {
        const date = new Date(isoString);
        const now = new Date();
        const seconds = Math.floor((now - date) / 1000);

        if (seconds < 60) return 'Just now';
        if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
        if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
        return `${Math.floor(seconds / 86400)}d ago`;
    }
}
```

##### 3.2. Integration with `AITimelineNavigator`

```javascript
// Modified AITimelineNavigator class
class AITimelineNavigator {
    // ... existing code ...

    filterByType(type) {
        this.activeFilter = type;

        // Update active tab
        document.querySelectorAll('.ai-nav-tab').forEach(tab => {
            tab.classList.remove('active');
        });
        document.querySelector(`.ai-nav-tab[data-type="${type}"]`).classList.add('active');

        // NEW: Show configuration panel for this category (if not "all")
        if (type !== 'all' && window.aiConfigPanel) {
            window.aiConfigPanel.showCategory(type);
        }

        // Re-render markers
        this.renderMarkers();
    }

    async updateCategoryResults(categoryId, newResults) {
        // Merge new results for single category into aiAnalysis
        this.aiAnalysis[categoryId] = newResults;

        // Save updated analysis to S3
        await this.saveAnalysis();

        // Re-render timeline
        this.render();
    }

    async saveAnalysis() {
        const userId = getUserId();
        const sessionFolder = currentSession.folder;
        const sessionPath = `users/${userId}/audio/sessions/${sessionFolder}`;
        const analysisKey = `${sessionPath}/transcription-ai-analysis.json`;

        // Upload to S3
        const uploadData = await apiCall(`/api/s3/upload/${encodeURIComponent(analysisKey)}`);
        await fetch(uploadData.uploadUrl, {
            method: 'PUT',
            body: JSON.stringify(this.aiAnalysis, null, 2),
            headers: {
                'Content-Type': 'application/json'
            }
        });
    }
}
```

### 4. Backend API Changes

#### 4.1. New Python Function: `analyze_single_category()`

**File**: `scripts/lib/ai-analysis.py`

```python
def analyze_single_category(
    transcript_text: str,
    category: str,
    custom_prompt: str,
    settings: Dict,
    total_duration: float
) -> Optional[Dict]:
    """
    Analyze transcript for a single category only

    Args:
        transcript_text: Formatted transcript with timestamps
        category: One of: actionItems, keyTerms, keyThemes, topicChanges, highlights
        custom_prompt: Custom prompt text for this category
        settings: Category-specific settings (maxItems, model, etc.)
        total_duration: Total duration in seconds

    Returns:
        {category: [...results...], _meta: {...}}
    """
    if not ANTHROPIC_API_KEY:
        logger.error("ANTHROPIC_API_KEY not set")
        return None

    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    # Build focused prompt for single category
    prompt = f"""Analyze this transcript and extract insights for the "{category}" category ONLY.

TRANSCRIPT (Duration: {format_time(total_duration)}):
{transcript_text}

{custom_prompt}

IMPORTANT RULES:
- All time codes must be in SECONDS as float (e.g., 45.2, not "0:45")
- Parse timestamps from [MM:SS] format in transcript
- Return ONLY valid JSON, no markdown, no explanation
- Return format: {{"results": [...]}}

Settings:
- Max items: {settings.get('maxItems', 15)}
"""

    try:
        logger.info(f"Analyzing category: {category}")

        message = client.messages.create(
            model=settings.get('model', 'claude-3-5-haiku-20241022'),
            max_tokens=settings.get('maxTokens', 8000),
            temperature=settings.get('temperature', 0.0),
            messages=[{"role": "user", "content": prompt}]
        )

        response_text = message.content[0].text
        category_data = json.loads(response_text)

        # Add metadata
        result = {
            category: category_data.get('results', []),
            '_meta': {
                'category': category,
                'generatedAt': datetime.utcnow().isoformat() + 'Z',
                'model': settings.get('model'),
                'tokens': message.usage.input_tokens + message.usage.output_tokens,
                'cost_estimate': calculate_cost(
                    message.usage.input_tokens,
                    message.usage.output_tokens,
                    settings.get('model')
                )
            }
        }

        logger.info(f"✅ Category '{category}' analyzed: {len(result[category])} items, ${result['_meta']['cost_estimate']:.4f}")
        return result

    except Exception as e:
        logger.error(f"Error analyzing category {category}: {e}")
        return None


def calculate_cost(input_tokens: int, output_tokens: int, model: str) -> float:
    """Calculate cost based on model pricing"""
    # Haiku: $0.25/MTok input, $1.25/MTok output
    # Sonnet: $3.00/MTok input, $15.00/MTok output

    if 'haiku' in model.lower():
        return (input_tokens * 0.25 + output_tokens * 1.25) / 1_000_000
    elif 'sonnet' in model.lower():
        return (input_tokens * 3.00 + output_tokens * 15.00) / 1_000_000
    else:
        return 0.0
```

#### 4.2. Lambda Function: `reanalyzeCategory`

**File**: `cognito-stack/api/ai-analysis.js`

```javascript
const AWS = require('aws-sdk');
const { execSync } = require('child_process');
const s3 = new AWS.S3();

const BUCKET = process.env.COGNITO_S3_BUCKET;

exports.reanalyzeCategory = async (event) => {
    try {
        const body = JSON.parse(event.body);
        const { sessionPath, category, prompt, settings } = body;

        // Validate inputs
        if (!sessionPath || !category || !prompt) {
            return {
                statusCode: 400,
                body: JSON.stringify({ error: 'Missing required fields' })
            };
        }

        // Load transcript
        const processedKey = `${sessionPath}/transcription-processed.json`;
        const transcriptObj = await s3.getObject({
            Bucket: BUCKET,
            Key: processedKey
        }).promise();

        const transcriptData = JSON.parse(transcriptObj.Body.toString());

        // Format transcript for analysis
        const transcriptText = formatTranscriptForAnalysis(transcriptData);
        const totalDuration = transcriptData.stats?.totalDuration || 0;

        // Call Python analysis (using Lambda layer or bundled)
        const result = await analyzeSingleCategory(
            transcriptText,
            category,
            prompt,
            settings,
            totalDuration
        );

        if (!result) {
            throw new Error('Analysis failed');
        }

        // Merge into existing analysis
        const analysisKey = `${sessionPath}/transcription-ai-analysis.json`;
        let existingAnalysis = {};

        try {
            const existing = await s3.getObject({
                Bucket: BUCKET,
                Key: analysisKey
            }).promise();
            existingAnalysis = JSON.parse(existing.Body.toString());
        } catch (err) {
            // First analysis, create new
        }

        // Update category
        existingAnalysis[category] = result[category];
        existingAnalysis._meta = existingAnalysis._meta || {};
        existingAnalysis._meta.lastModified = new Date().toISOString();
        existingAnalysis._meta[`${category}Updated`] = new Date().toISOString();

        // Save back to S3
        await s3.putObject({
            Bucket: BUCKET,
            Key: analysisKey,
            Body: JSON.stringify(existingAnalysis, null, 2),
            ContentType: 'application/json'
        }).promise();

        return {
            statusCode: 200,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Credentials': true
            },
            body: JSON.stringify({
                success: true,
                category,
                count: result[category].length,
                cost: result._meta.cost_estimate,
                tokens: result._meta.tokens
            })
        };

    } catch (error) {
        console.error('Error reanalyzing category:', error);
        return {
            statusCode: 500,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Credentials': true
            },
            body: JSON.stringify({ error: error.message })
        };
    }
};

function formatTranscriptForAnalysis(transcriptData) {
    const paragraphs = transcriptData.paragraphs || [];
    const lines = [];

    for (let para of paragraphs) {
        const mins = Math.floor(para.start / 60);
        const secs = Math.floor(para.start % 60);
        const timestamp = `${mins}:${secs.toString().padStart(2, '0')}`;
        lines.push(`[${timestamp}] ${para.text}`);
    }

    return lines.join('\n\n');
}

async function analyzeSingleCategory(transcriptText, category, prompt, settings, totalDuration) {
    // Call Python function via subprocess or Lambda layer
    // Implementation depends on deployment method
    // For now, return mock data

    // TODO: Implement actual Python integration
    return {
        [category]: [],
        _meta: {
            category,
            generatedAt: new Date().toISOString(),
            model: settings.model,
            tokens: 0,
            cost_estimate: 0
        }
    };
}
```

### 5. UX Flow - Complete User Journey

```
1. User loads transcript editor
   ↓
2. AI timeline loads with default analysis
   ↓
3. User clicks "Highlights" tab
   ↓
4. Timeline filters to show only highlights
   AND
   Left sidebar transitions: Session Info → Config Panel (300ms slide)
   ↓
5. Config panel shows:
   - Tab name: "Highlights" (editable)
   - Prompt: [collapsed, 3 lines visible]
   - Settings: Model, Max Items, Min Importance
   - Status: Last analyzed 2m ago, $0.0008, 12 items
   - Buttons: Re-analyze, Save, Reset
   ↓
6. User edits:
   - Changes name to "Key Interviewer Questions"
   - Expands prompt, modifies to focus on questions
   - Changes Max Items to 20
   ↓
7. Save button activates (orange border = dirty)
   ↓
8. User clicks "Save Configuration"
   → Uploads ai-config.json to S3
   → Success toast
   ↓
9. User clicks "Re-analyze This Category"
   ↓
10. Progress indicator:
    - Spinner animation
    - ETA: "~10s remaining"
    - All inputs disabled
    ↓
11. Backend:
    - Loads transcript from S3
    - Calls Claude API with custom prompt
    - Parses JSON response
    - Merges into transcription-ai-analysis.json
    - Saves to S3
    ↓
12. Frontend updates:
    - Timeline: Remove old markers, fade in new ones
    - Count badge: "Highlights (18)" with count-up animation
    - Status: "Last analyzed: Just now"
    - Success checkmark (2s)
    ↓
13. User can:
    - Click other tabs to configure them
    - Click "Back to Session Info" to close panel
    - Switch sessions (resets all state)
```

### 6. Cost Optimization

**Per-Category Re-analysis Savings:**
- Full re-analysis: ~$0.0045 (all 5 categories)
- Single category: ~$0.0009 (1 category only)
- **Savings: 80%** when updating just one category

**Estimated Token Counts:**

| Category | Avg Input | Avg Output | Cost (Haiku) | Cost (Sonnet) |
|----------|-----------|------------|--------------|---------------|
| Highlights | 2,500 | 600 | $0.0009 | $0.0165 |
| Action Items | 2,500 | 400 | $0.0008 | $0.0135 |
| Key Terms | 2,500 | 500 | $0.0008 | $0.0150 |
| Key Themes | 2,500 | 450 | $0.0008 | $0.0143 |
| Topic Changes | 2,500 | 350 | $0.0007 | $0.0128 |

### 7. Implementation Phases

#### Phase 1: Core Configuration UI (3-4 days)
- [ ] Add HTML structure for config panel
- [ ] Add CSS styling and animations
- [ ] Create `AIConfigPanel` class
- [ ] Implement config load/save to S3
- [ ] Create default prompts JSON file
- [ ] Integrate with tab click handlers
- [ ] Add sidebar transition animations

#### Phase 2: Settings Management (2 days)
- [ ] Implement category-specific settings rendering
- [ ] Add dirty state detection
- [ ] Add validation for inputs
- [ ] Implement reset to defaults
- [ ] Add keyboard shortcuts
- [ ] Test mobile responsiveness

#### Phase 3: Backend Re-analysis (2-3 days)
- [ ] Add `analyze_single_category()` to Python
- [ ] Create Lambda function `reanalyzeCategory`
- [ ] Deploy Lambda with AI analysis dependencies
- [ ] Test single-category analysis
- [ ] Implement cost tracking
- [ ] Add error handling and retries

#### Phase 4: Integration & Polish (2 days)
- [ ] Wire frontend to backend API
- [ ] Add progress indicators and ETAs
- [ ] Implement success/error animations
- [ ] Test all 5 categories individually
- [ ] Add loading states
- [ ] Performance testing

#### Phase 5: Documentation & Deployment (1 day)
- [ ] Update CHANGELOG
- [ ] Create user guide
- [ ] Add tooltips and help text
- [ ] Deploy to production
- [ ] User acceptance testing

**Total: 10-12 days**

### 8. Future Enhancements

- **Preset Templates**: Load "Interview", "Meeting", "Lecture" configurations
- **A/B Testing**: Compare different prompts side-by-side
- **Sharing**: Export/import custom configurations
- **Analytics**: Track which prompts produce best results
- **Batch Apply**: Apply same configuration to multiple sessions
- **Prompt Library**: Community-shared prompts
- **Auto-optimization**: AI suggests prompt improvements based on results

---

## Summary

This design provides a complete solution for per-category AI configuration:

✅ **Completed**: Basic AI timeline with 5 insight types, interactive navigation, cost-effective analysis

🚧 **Next**: Per-tab configuration UI with customizable prompts, settings, and granular re-analysis

**Key Benefits**:
1. **Customizable** - Rename tabs and edit prompts per use case
2. **Cost-Effective** - Re-analyze only changed categories (80% savings)
3. **Flexible** - Category-specific settings with validation
4. **Persistent** - Configurations saved per session
5. **User-Friendly** - Smooth animations, clear status, helpful errors

**Ready to begin Phase 1 implementation?**
