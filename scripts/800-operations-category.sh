#!/bin/bash
set -euo pipefail

cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                                                                            ║
║                      ⚙️  OPERATIONS SCRIPTS (8xx)                         ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝

This category contains scripts for daily operations: shutting down the GPU
to save costs, starting it back up, and restoring full working state.

═══════════════════════════════════════════════════════════════════════════

SCRIPTS IN THIS CATEGORY:

  810-shutdown-gpu.sh
    • Safely shutdown GPU EC2 instance
    • Preserves all model data on EBS volume
    • Saves ~$0.526/hour (only EBS storage charges while stopped)
    • Takes 30-60 seconds

  820-startup-restore.sh  ⭐ PRIMARY SCRIPT
    • One-command restoration of full working state
    • Starts GPU instance (2-3 min wait)
    • Handles IP address changes automatically
    • Updates .env and security groups
    • Verifies/deploys Conformer-CTC model if needed
    • Restarts WebSocket bridge service
    • Total time: 5-10 minutes
    • This is what you run every morning!

═══════════════════════════════════════════════════════════════════════════

DAILY WORKFLOW:

  End of Day:
    ./scripts/810-shutdown-gpu.sh

  Next Morning:
    ./scripts/820-startup-restore.sh

  The startup script handles everything automatically, including:
    ✓ IP address changes
    ✓ Security group updates
    ✓ Model verification
    ✓ Service restarts

═══════════════════════════════════════════════════════════════════════════

COST SAVINGS:

  GPU Instance (g4dn.xlarge):
    • Running: ~$0.526/hour
    • Stopped: Only EBS storage (~$20/month for 200GB)

  If you work 8 hours/day, 5 days/week:
    • Monthly running cost: ~$84
    • Monthly with shutdown: ~$43 + $20 storage = ~$63
    • Savings: ~$21/month

═══════════════════════════════════════════════════════════════════════════

After startup completes, test at: https://${BUILDBOX_PUBLIC_IP:-3.16.124.227}:${DEMO_PORT:-8444}/demo.html

EOF
