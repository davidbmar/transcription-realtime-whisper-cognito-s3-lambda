#!/bin/bash
# ============================================================================
# Log Viewer Utility
# ============================================================================
# View recent script execution logs
# ============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$REPO_ROOT/logs"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Recent Script Executions${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [ ! -d "$LOG_DIR" ] || [ -z "$(ls -A $LOG_DIR 2>/dev/null)" ]; then
    echo -e "${YELLOW}No logs found${NC}"
    exit 0
fi

echo -e "${BLUE}Last 10 script executions:${NC}"
echo ""

ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -10 | while read logfile; do
    filename=$(basename "$logfile")
    script_name=$(echo "$filename" | sed 's/-[0-9]\{8\}-[0-9]\{6\}\.log$//')
    timestamp=$(echo "$filename" | grep -oP '\d{8}-\d{6}' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
    size=$(du -h "$logfile" | cut -f1)

    echo -e "${GREEN}•${NC} ${CYAN}$script_name${NC}"
    echo -e "  Time: $timestamp  Size: $size"
    echo -e "  File: $filename"
    echo ""
done

echo ""
echo -e "${YELLOW}Usage:${NC}"
echo -e "  View a log: ${GREEN}cat logs/LOGFILE.log${NC}"
echo -e "  Follow latest: ${GREEN}tail -f logs/\$(ls -t logs/*.log | head -1)${NC}"
echo -e "  Clean old logs: ${GREEN}rm logs/*.log${NC}"
echo ""
