# Documentation Organization

This directory contains all project documentation organized by category.

## 📂 Directory Structure

### `/changelogs/`
Version-specific changelogs documenting features, fixes, and changes:
- `CHANGELOG-v6.7.0.md` - Wake Lock API + corruption fixes
- `CHANGELOG-v6.8.0.md` - Enhanced diagnostics

### `/deployment/`
Deployment summaries and completion reports:
- `DEPLOYMENT-v6.4.0-SUMMARY.md` - v6.4.0 deployment
- `DEPLOYMENT-v6.5.0-SUMMARY.md` - v6.5.0 deployment
- `DEPLOYMENT-v6.6.0-SUMMARY.md` - v6.6.0 deployment (major)
- `DEPLOYMENT-FIXES-SUMMARY.md` - Critical deployment fixes
- `INDEXEDDB-INTEGRATION-COMPLETE.md` - IndexedDB feature completion
- `PHASE-1-COMPLETE.md` - Download/export features
- `PHASE-2-COMPLETE.md` - Upload queue with retry

### `/archive/`
Historical documentation kept for reference:
- `NEXT-TASK.md` - Old task planning (superseded by CLAUDE.md)
- `FRESH-CLONE-DEPLOYMENT-TEST.md` - Historical deployment test
- `QUICK-START-PHASE-2.md` - Old quick start guide
- `boundary-dedup-summary.md` - Boundary deduplication analysis
- `IMPORTANT-TEMPLATE-SYSTEM.md` - Template system documentation (now in ui-source/README.md)

## 📄 Root-Level Documentation

Key documentation files remain in the project root:

- **[../CLAUDE.md](../CLAUDE.md)** - ⭐ **Primary development guide for Claude Code**
- **[../README.md](../README.md)** - Project overview and quick start
- **[../AUTOMATED-TESTING.md](../AUTOMATED-TESTING.md)** - Browser automation testing
- **[../BROWSER-DEBUG.md](../BROWSER-DEBUG.md)** - Debugging guide
- **[../DNS-LETSENCRYPT-SETUP.md](../DNS-LETSENCRYPT-SETUP.md)** - Domain configuration

## 🔍 Finding Documentation

**For developers:**
1. Start with [../CLAUDE.md](../CLAUDE.md) - comprehensive development guide
2. Check [../README.md](../README.md) - project overview
3. Browse `/changelogs/` for version-specific changes
4. Check `/deployment/` for feature completion status

**For specific topics:**
- Template system: `../ui-source/README.md`
- Testing: `../AUTOMATED-TESTING.md`
- Debugging: `../BROWSER-DEBUG.md`
- DNS setup: `../DNS-LETSENCRYPT-SETUP.md`
- Script patterns: `../.claude/skills/script-template/SKILL.md`

## 📝 Documentation Standards

When adding new documentation:

1. **Changelogs** → `/changelogs/CHANGELOG-vX.Y.Z.md`
2. **Deployment summaries** → `/deployment/DEPLOYMENT-*.md`
3. **Feature completions** → `/deployment/FEATURE-*-COMPLETE.md`
4. **Outdated docs** → `/archive/` (keep for historical reference)
5. **Current guides** → Keep in project root or relevant subdirectories

## 🗂️ Archive Policy

Documents are archived (not deleted) when:
- Superseded by newer documentation
- No longer relevant to current development
- Historical value but not actively referenced
- Specific to old versions or deprecated features
