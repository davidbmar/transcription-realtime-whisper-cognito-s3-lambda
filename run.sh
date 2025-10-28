#!/bin/bash
# ============================================================================
# Interactive Script Runner
# ============================================================================
# Simple menu to run deployment scripts with clear descriptions
# ============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  WhisperLive Transcription - Script Runner                ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}SETUP & CONFIGURATION${NC}"
echo -e "${GREEN}  1)${NC} 005-setup-configuration.sh     - Interactive .env configuration"
echo -e "${GREEN}  2)${NC} 010-setup-edge-box.sh          - Setup Caddy reverse proxy"
echo -e "${GREEN}  3)${NC} 031-configure-edge-box-security.sh - Manage client access"
echo ""

echo -e "${YELLOW}GPU INSTANCE MANAGEMENT${NC}"
echo -e "${GREEN}  4)${NC} 020-deploy-gpu-instance.sh     - Create new GPU EC2 instance"
echo -e "${GREEN}  5)${NC} 021-setup-gpu-s3-access.sh     - Configure S3 model access"
echo -e "${GREEN}  6)${NC} 030-configure-gpu-security.sh  - Configure GPU security groups"
echo ""

echo -e "${YELLOW}DAILY OPERATIONS${NC}"
echo -e "${GREEN}  7)${NC} 820-startup-restore.sh         - Start GPU + WhisperLive (1-5 min)"
echo -e "${GREEN}  8)${NC} 810-shutdown-gpu.sh            - Stop GPU (save \$0.526/hour)"
echo -e "${GREEN}  9)${NC} 310-configure-whisperlive-gpu.sh - Deploy/configure WhisperLive"
echo ""

echo -e "${YELLOW}OTHER${NC}"
echo -e "${GREEN}  0)${NC} Exit"
echo ""

read -p "Select script to run (0-9): " choice

case $choice in
    1)
        echo -e "${BLUE}Running: 005-setup-configuration.sh${NC}"
        ./scripts/005-setup-configuration.sh
        ;;
    2)
        echo -e "${BLUE}Running: 010-setup-edge-box.sh${NC}"
        ./scripts/010-setup-edge-box.sh
        ;;
    3)
        echo -e "${BLUE}Running: 031-configure-edge-box-security.sh${NC}"
        ./scripts/031-configure-edge-box-security.sh
        ;;
    4)
        echo -e "${BLUE}Running: 020-deploy-gpu-instance.sh${NC}"
        ./scripts/020-deploy-gpu-instance.sh
        ;;
    5)
        echo -e "${BLUE}Running: 021-setup-gpu-s3-access.sh${NC}"
        ./scripts/021-setup-gpu-s3-access.sh
        ;;
    6)
        echo -e "${BLUE}Running: 030-configure-gpu-security.sh${NC}"
        ./scripts/030-configure-gpu-security.sh
        ;;
    7)
        echo -e "${BLUE}Running: 820-startup-restore.sh${NC}"
        echo -e "${YELLOW}This will start the GPU and may take 1-5 minutes...${NC}"
        ./scripts/820-startup-restore.sh
        ;;
    8)
        echo -e "${BLUE}Running: 810-shutdown-gpu.sh${NC}"
        ./scripts/810-shutdown-gpu.sh
        ;;
    9)
        echo -e "${BLUE}Running: 310-configure-whisperlive-gpu.sh${NC}"
        ./scripts/310-configure-whisperlive-gpu.sh
        ;;
    0)
        echo "Goodbye!"
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac
