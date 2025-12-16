#!/bin/bash
#===============================================================================
# 998-DASHBOARD--generate-gpu-status.sh
# Generates HTML dashboard of GPU status and uploads to S3
#===============================================================================
#
# WHAT THIS SCRIPT DOES:
# ----------------------
# Creates a static HTML dashboard showing:
#   - Currently running GPU resources (RunPod + AWS)
#   - Event history from last 24 hours
#   - Cost summary
#   - Activity timeline
#
# Uploads to S3 for easy viewing in a browser.
#
# USAGE:
#   ./scripts/998-DASHBOARD--generate-gpu-status.sh
#
# S3 CONFIGURATION:
#   Set GPU_DASHBOARD_S3_BUCKET in .env or environment
#   Default: s3://your-bucket/gpu-dashboard/
#
#===============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/gpu-event-logger.sh" 2>/dev/null || true

# Load environment
ENV_FILE="$SCRIPT_DIR/../.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

RUNPOD_API_KEY="${RUNPOD_API_KEY:-}"
S3_BUCKET="${GPU_DASHBOARD_S3_BUCKET:-}"
OUTPUT_DIR="$SCRIPT_DIR/../artifacts"
OUTPUT_FILE="$OUTPUT_DIR/gpu-dashboard.html"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

mkdir -p "$OUTPUT_DIR"

#===============================================================================
# Gather current state
#===============================================================================

get_runpod_status() {
    if [ -z "$RUNPOD_API_KEY" ]; then
        echo "[]"
        return
    fi

    # Try GraphQL API first (has costPerHr field)
    local graphql_response=$(curl -s --max-time 10 -X POST "https://api.runpod.io/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        -d '{"query": "{ myself { pods { id name desiredStatus costPerHr createdAt machine { gpuDisplayName } runtime { uptimeInSeconds } } } }"}' 2>/dev/null)

    # Check if GraphQL succeeded
    local pods=$(echo "$graphql_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Check for error response
    if 'error' in data or 'errors' in data:
        print('GRAPHQL_FAILED')
    else:
        pods = data.get('data', {}).get('myself', {}).get('pods', [])
        if pods:
            for pod in pods:
                pod['machine'] = pod.get('machine', {})
                pod['machine']['gpuDisplayName'] = pod.get('machine', {}).get('gpuDisplayName', 'unknown')
            print(json.dumps(pods))
        else:
            print('GRAPHQL_EMPTY')
except:
    print('GRAPHQL_FAILED')
" 2>/dev/null)

    # If GraphQL worked and has data, use it
    if [[ "$pods" != "GRAPHQL_FAILED" && "$pods" != "GRAPHQL_EMPTY" && -n "$pods" ]]; then
        echo "$pods"
        return
    fi

    # Fallback to REST API (more reliable, but missing some fields)
    local rest_response=$(curl -s --max-time 10 "https://rest.runpod.io/v1/pods" \
        -H "Authorization: Bearer ${RUNPOD_API_KEY}" 2>/dev/null)

    # Normalize REST API response to match GraphQL format
    echo "$rest_response" | python3 -c "
import sys, json
try:
    pods = json.load(sys.stdin)
    if isinstance(pods, list):
        for pod in pods:
            # Normalize machine field
            if 'machine' not in pod or not pod['machine']:
                pod['machine'] = {'gpuDisplayName': 'unknown'}
            # REST API uses different field names sometimes
            if 'gpuDisplayName' not in pod.get('machine', {}):
                pod['machine']['gpuDisplayName'] = pod.get('gpu', 'unknown')
        print(json.dumps(pods))
    else:
        print('[]')
except:
    print('[]')
" 2>/dev/null || echo "[]"
}

get_aws_gpu_status() {
    aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running,pending,stopping" \
        --query "Reservations[*].Instances[*].{id:InstanceId,type:InstanceType,state:State.Name,launch:LaunchTime,name:Tags[?Key=='Name'].Value|[0]}" \
        --output json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
gpu_types = ['g4dn', 'g5', 'p3', 'p4d', 'p5', 'g3', 'g6']
result = []
for reservation in data:
    for inst in reservation:
        if any(gt in inst.get('type', '') for gt in gpu_types):
            result.append(inst)
print(json.dumps(result))
" 2>/dev/null || echo "[]"
}

RUNPOD_DATA=$(get_runpod_status)
AWS_DATA=$(get_aws_gpu_status)
EVENT_LOG="${GPU_EVENT_LOG:-$SCRIPT_DIR/../logs/gpu-events.jsonl}"

#===============================================================================
# Generate HTML
#===============================================================================

cat > "$OUTPUT_FILE" << 'HTMLHEADER'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GPU Cost Guardian</title>
    <meta http-equiv="refresh" content="300">
    <meta name="dashboard-date" content="__DASHBOARD_DATE__">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            color: #333;
            padding: 20px;
            line-height: 1.6;
        }
        .header {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            padding: 1rem 2rem;
            box-shadow: 0 2px 20px rgba(0, 0, 0, 0.1);
            border-radius: 12px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }
        .logo {
            display: flex;
            align-items: center;
            font-size: 1.5rem;
            font-weight: bold;
            color: #667eea;
        }
        .logo i {
            margin-right: 0.5rem;
            font-size: 1.8rem;
        }
        .nav-link {
            display: flex;
            align-items: center;
            gap: 6px;
            color: #667eea;
            text-decoration: none;
            padding: 8px 16px;
            border-radius: 8px;
            transition: all 0.2s;
            font-weight: 500;
        }
        .nav-link:hover {
            background: rgba(102, 126, 234, 0.1);
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h2 {
            color: white;
            font-size: 14px;
            text-transform: uppercase;
            margin: 25px 0 12px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        h2 i { font-size: 16px; }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }
        .card {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 12px;
            padding: 20px;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1);
        }
        .card-icon {
            width: 48px;
            height: 48px;
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
            margin-bottom: 12px;
        }
        .card-icon.gpu { background: linear-gradient(45deg, #667eea, #764ba2); color: white; }
        .card-icon.runpod { background: linear-gradient(45deg, #6e40c9, #9333ea); color: white; }
        .card-icon.aws { background: linear-gradient(45deg, #ff9900, #ffb84d); color: white; }
        .card-icon.cost { background: linear-gradient(45deg, #ef4444, #f87171); color: white; }
        .card-title { color: #6b7280; font-size: 13px; margin-bottom: 4px; }
        .card-value { color: #1f2937; font-size: 32px; font-weight: bold; }
        .card-value.cost { color: #ef4444; }
        .card-value.running { color: #10b981; }
        .resource-table {
            width: 100%;
            border-collapse: collapse;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1);
            margin-bottom: 20px;
        }
        .resource-table th, .resource-table td {
            padding: 14px 16px;
            text-align: left;
        }
        .resource-table th {
            background: rgba(102, 126, 234, 0.1);
            color: #667eea;
            font-size: 12px;
            text-transform: uppercase;
            font-weight: 600;
        }
        .resource-table tr:not(:last-child) td {
            border-bottom: 1px solid #e5e7eb;
        }
        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
        }
        .status-running { background: #d1fae5; color: #059669; }
        .status-idle { background: #fef3c7; color: #d97706; }
        .status-terminated { background: #fee2e2; color: #dc2626; }
        .provider-badge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 11px;
            font-weight: 600;
        }
        .provider-runpod { background: #ede9fe; color: #7c3aed; }
        .provider-aws { background: #fff7ed; color: #ea580c; }
        .event-log {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 12px;
            padding: 16px;
            max-height: 400px;
            overflow-y: auto;
            font-family: 'Monaco', 'Menlo', monospace;
            font-size: 12px;
        }
        .event-row {
            padding: 8px 12px;
            border-bottom: 1px solid #e5e7eb;
        }
        .event-row:hover { background: rgba(102, 126, 234, 0.05); }
        .event-time { color: #6b7280; margin-right: 8px; }
        .event-action-created { color: #10b981; font-weight: 600; }
        .event-action-terminated { color: #ef4444; font-weight: 600; }
        .event-action-checked { color: #667eea; font-weight: 600; }
        .timestamp {
            color: rgba(255, 255, 255, 0.8);
            font-size: 13px;
            margin-top: 25px;
            text-align: center;
        }
        .timestamp a { color: white; }
        .no-data {
            color: #6b7280;
            text-align: center;
            padding: 40px;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 12px;
            margin-bottom: 20px;
        }
        .cost-warning {
            background: linear-gradient(135deg, #dc2626 0%, #b91c1c 100%);
            border: none;
            border-radius: 12px;
            padding: 16px 20px;
            margin-bottom: 20px;
            color: white;
            display: flex;
            align-items: center;
            gap: 12px;
            font-weight: 500;
            box-shadow: 0 4px 15px rgba(220, 38, 38, 0.3);
        }
        .cost-warning code {
            background: rgba(255, 255, 255, 0.2);
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 12px;
        }
        .settings-table td { padding: 8px 0; }
        .settings-table td:first-child { color: #6b7280; }
        .rule-ok { color: #10b981; }
        .rule-warn { color: #f59e0b; }
        .rule-kill { color: #ef4444; }
        .code-block {
            background: #1f2937;
            color: #e5e7eb;
            padding: 12px;
            border-radius: 8px;
            margin: 10px 0;
            font-family: 'Monaco', 'Menlo', monospace;
            font-size: 12px;
            overflow-x: auto;
        }
        .timeline-container {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1);
        }
        .timeline-header {
            display: flex;
            justify-content: space-between;
            margin-bottom: 10px;
            font-size: 12px;
            color: #6b7280;
        }
        .timeline-track {
            position: relative;
            height: 40px;
            background: #f3f4f6;
            border-radius: 8px;
            margin: 8px 0;
            overflow: hidden;
        }
        .timeline-bar {
            position: absolute;
            height: 100%;
            border-radius: 6px;
            display: flex;
            align-items: center;
            padding: 0 12px;
            font-size: 11px;
            font-weight: 600;
            color: white;
            white-space: nowrap;
        }
        .timeline-bar.runpod { background: linear-gradient(90deg, #7c3aed, #9333ea); }
        .timeline-bar.aws { background: linear-gradient(90deg, #ea580c, #f97316); }
        .timeline-bar.running {
            background: linear-gradient(90deg, #10b981, #34d399);
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.8; }
        }
        /* Start/end markers */
        .timeline-bar::before {
            content: '';
            position: absolute;
            left: 0;
            top: -2px;
            bottom: -2px;
            width: 6px;
            background: #10b981;
            border-radius: 3px;
            box-shadow: 0 0 4px rgba(16, 185, 129, 0.5);
        }
        .timeline-bar.ended::after {
            content: '';
            position: absolute;
            right: 0;
            top: -2px;
            bottom: -2px;
            width: 6px;
            background: #ef4444;
            border-radius: 3px;
            box-shadow: 0 0 4px rgba(239, 68, 68, 0.5);
        }
        .timeline-bar.running::after {
            content: '';
            position: absolute;
            right: 0;
            top: -2px;
            bottom: -2px;
            width: 6px;
            background: #10b981;
            border-radius: 3px;
            box-shadow: 0 0 6px rgba(16, 185, 129, 0.8);
            animation: pulse 1s infinite;
        }
        .timeline-label {
            font-size: 12px;
            font-weight: 600;
            color: #374151;
            margin-bottom: 4px;
        }
        .timeline-hours {
            display: flex;
            justify-content: space-between;
            font-size: 10px;
            color: #9ca3af;
            padding: 0 2px;
        }
        .timeline-legend {
            display: flex;
            gap: 16px;
            margin-top: 12px;
            font-size: 12px;
        }
        .legend-item {
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .legend-dot {
            width: 12px;
            height: 12px;
            border-radius: 4px;
        }
        .legend-dot.runpod { background: #7c3aed; }
        .legend-dot.aws { background: #ea580c; }
        .legend-dot.running { background: #10b981; }
        /* Date navigation */
        .date-nav {
            display: flex;
            align-items: center;
            gap: 12px;
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            padding: 12px 20px;
            border-radius: 12px;
            margin-bottom: 20px;
            box-shadow: 0 2px 10px rgba(0, 0, 0, 0.1);
        }
        .date-nav-btn {
            display: flex;
            align-items: center;
            justify-content: center;
            width: 36px;
            height: 36px;
            border-radius: 8px;
            border: none;
            background: #667eea;
            color: white;
            cursor: pointer;
            transition: all 0.2s;
            text-decoration: none;
        }
        .date-nav-btn:hover { background: #5a67d8; transform: scale(1.05); }
        .date-nav-btn:disabled, .date-nav-btn.disabled {
            background: #d1d5db;
            cursor: not-allowed;
            transform: none;
        }
        .date-display {
            font-size: 18px;
            font-weight: 600;
            color: #374151;
            min-width: 140px;
            text-align: center;
        }
        .date-display small {
            display: block;
            font-size: 11px;
            font-weight: normal;
            color: #6b7280;
        }
        .tz-selector {
            margin-left: auto;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .tz-selector label {
            font-size: 12px;
            color: #6b7280;
        }
        .tz-selector select {
            padding: 6px 10px;
            border-radius: 6px;
            border: 1px solid #d1d5db;
            font-size: 12px;
            background: white;
            cursor: pointer;
        }
        .live-badge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            background: #10b981;
            color: white;
            padding: 4px 10px;
            border-radius: 12px;
            font-size: 11px;
            font-weight: 600;
            animation: pulse 2s infinite;
        }
        .archive-badge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            background: #6b7280;
            color: white;
            padding: 4px 10px;
            border-radius: 12px;
            font-size: 11px;
            font-weight: 600;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="logo">
                <i class="fas fa-shield-alt"></i>
                GPU Cost Guardian
            </div>
            <div style="text-align: center; font-size: 12px; color: #6b7280;">
                <i class="fas fa-clock"></i> Updated: <span class="local-time" data-utc="__TIMESTAMP_ISO__">__TIMESTAMP__</span>
                <span id="live-indicator"></span>
            </div>
            <a href="https://d2l28rla2hk7np.cloudfront.net/index.html" class="nav-link">
                <i class="fas fa-arrow-left"></i>
                Back to CloudDrive
            </a>
        </div>

        <!-- Date Navigation -->
        <div class="date-nav">
            <a id="prev-day" class="date-nav-btn" title="Previous day">
                <i class="fas fa-chevron-left"></i>
            </a>
            <div class="date-display">
                <span id="display-date">__DASHBOARD_DATE__</span>
                <small id="display-date-label">UTC</small>
            </div>
            <a id="next-day" class="date-nav-btn" title="Next day">
                <i class="fas fa-chevron-right"></i>
            </a>
            <a href="index.html" class="date-nav-btn" title="Today (Live)" style="margin-left: 8px; width: auto; padding: 0 12px;">
                <i class="fas fa-broadcast-tower"></i>&nbsp;Live
            </a>
            <div class="tz-selector">
                <label for="timezone"><i class="fas fa-globe"></i></label>
                <select id="timezone">
                    <option value="UTC">UTC</option>
                    <option value="America/Chicago">Central (Austin)</option>
                    <option value="America/New_York">Eastern</option>
                    <option value="America/Denver">Mountain</option>
                    <option value="America/Los_Angeles">Pacific</option>
                    <option value="Europe/London">London</option>
                    <option value="Europe/Paris">Paris</option>
                    <option value="Asia/Tokyo">Tokyo</option>
                </select>
            </div>
        </div>
HTMLHEADER

# Replace placeholders
TODAY=$(date -u +"%Y-%m-%d")
TIMESTAMP_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s|__TIMESTAMP__|$(date -u '+%Y-%m-%d %H:%M:%S UTC')|g" "$OUTPUT_FILE"
sed -i "s|__TIMESTAMP_ISO__|${TIMESTAMP_ISO}|g" "$OUTPUT_FILE"
sed -i "s|__DASHBOARD_DATE__|${TODAY}|g" "$OUTPUT_FILE"

# Add summary cards
RUNPOD_COUNT=$(echo "$RUNPOD_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([p for p in d if p.get('desiredStatus')=='RUNNING']))" 2>/dev/null || echo "0")
AWS_COUNT=$(echo "$AWS_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
TOTAL_RUNNING=$((RUNPOD_COUNT + AWS_COUNT))

# Calculate hourly cost
HOURLY_COST=$(echo "$RUNPOD_DATA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
total = sum(p.get('costPerHr', 0) for p in data if p.get('desiredStatus') == 'RUNNING')
print(f'{total:.2f}')
" 2>/dev/null || echo "0.00")

cat >> "$OUTPUT_FILE" << HTMLSUMMARY
        <div class="summary-cards">
            <div class="card">
                <div class="card-icon gpu"><i class="fas fa-microchip"></i></div>
                <div class="card-title">Running Now</div>
                <div class="card-value ${TOTAL_RUNNING:+running}">${TOTAL_RUNNING} GPU${TOTAL_RUNNING:+s}</div>
                <div style="font-size: 12px; color: #6b7280; margin-top: 4px;">${RUNPOD_COUNT} RunPod · ${AWS_COUNT} AWS</div>
            </div>
            <div class="card">
                <div class="card-icon cost"><i class="fas fa-dollar-sign"></i></div>
                <div class="card-title">Current Cost</div>
                <div class="card-value cost">\$${HOURLY_COST}/hr</div>
            </div>
        </div>
HTMLSUMMARY

# Add warning if resources are running
if [ "$TOTAL_RUNNING" -gt 0 ]; then
    cat >> "$OUTPUT_FILE" << 'HTMLWARN'
        <div class="cost-warning">
            ⚠️ <strong>GPU resources are currently running!</strong> Make sure these are intentional.
            Run <code>./scripts/999-WATCHDOG--gpu-cost-guardian.sh --kill</code> to terminate idle resources.
        </div>
HTMLWARN
fi

# Only show RunPod table if pods are running
if [ "$RUNPOD_COUNT" -gt 0 ]; then
cat >> "$OUTPUT_FILE" << 'HTMLRUNPOD'
        <h2><i class="fas fa-server"></i> Active RunPod Pods</h2>
HTMLRUNPOD
    cat >> "$OUTPUT_FILE" << 'HTMLTABLE1'
        <table class="resource-table">
            <tr>
                <th>Pod ID</th>
                <th>Name</th>
                <th>GPU</th>
                <th>Status</th>
                <th>Cost/Hr</th>
                <th>Runtime</th>
            </tr>
HTMLTABLE1

    echo "$RUNPOD_DATA" | python3 -c "
import sys, json
from datetime import datetime, timezone, timedelta

data = json.load(sys.stdin)
now = datetime.now(timezone.utc)

for pod in data:
    if pod.get('desiredStatus') != 'RUNNING':
        continue
    pod_id = pod.get('id', 'unknown')
    name = pod.get('name', 'unnamed')
    gpu = pod.get('machine', {}).get('gpuDisplayName', 'unknown')
    cost = pod.get('costPerHr', 0)
    created_str = pod.get('createdAt', '')

    # Calculate runtime
    runtime_str = 'unknown'
    try:
        # Parse RunPod format: '2025-12-15 18:04:36.612 +0000 UTC'
        created_clean = created_str.replace(' UTC', '').replace(' +0000', '')
        created = datetime.strptime(created_clean.split('.')[0], '%Y-%m-%d %H:%M:%S')
        created = created.replace(tzinfo=timezone.utc)
        delta = now - created
        mins = int(delta.total_seconds() / 60)
        if mins < 60:
            runtime_str = f'{mins}m'
        else:
            hours = mins // 60
            remaining_mins = mins % 60
            runtime_str = f'{hours}h {remaining_mins}m'
    except:
        pass

    print(f'''<tr>
        <td><code>{pod_id}</code></td>
        <td>{name}</td>
        <td>{gpu}</td>
        <td><span class=\"status-badge status-running\">RUNNING</span></td>
        <td>\${cost:.2f}</td>
        <td><strong>{runtime_str}</strong></td>
    </tr>''')
" >> "$OUTPUT_FILE"

    echo "        </table>" >> "$OUTPUT_FILE"
fi

# Only show AWS table if instances are running
if [ "$AWS_COUNT" -gt 0 ]; then
cat >> "$OUTPUT_FILE" << 'HTMLAWS'
        <h2><i class="fab fa-aws"></i> Active AWS GPU Instances</h2>
HTMLAWS
    cat >> "$OUTPUT_FILE" << 'HTMLTABLE2'
        <table class="resource-table">
            <tr>
                <th>Instance ID</th>
                <th>Name</th>
                <th>Type</th>
                <th>Status</th>
                <th>Runtime</th>
            </tr>
HTMLTABLE2

    echo "$AWS_DATA" | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
now = datetime.now(timezone.utc)

for inst in data:
    inst_id = inst.get('id', 'unknown')
    name = inst.get('name', 'unnamed') or 'unnamed'
    inst_type = inst.get('type', 'unknown')
    state = inst.get('state', 'unknown')
    launch_str = inst.get('launch', '')

    # Calculate runtime
    runtime_str = 'unknown'
    try:
        launch = datetime.fromisoformat(launch_str.replace('Z', '+00:00'))
        delta = now - launch
        mins = int(delta.total_seconds() / 60)
        if mins < 60:
            runtime_str = f'{mins}m'
        else:
            hours = mins // 60
            remaining_mins = mins % 60
            runtime_str = f'{hours}h {remaining_mins}m'
    except:
        pass

    status_class = 'status-running' if state == 'running' else 'status-idle'
    print(f'''<tr>
        <td><code>{inst_id}</code></td>
        <td>{name}</td>
        <td>{inst_type}</td>
        <td><span class=\"status-badge {status_class}\">{state.upper()}</span></td>
        <td><strong>{runtime_str}</strong></td>
    </tr>''')
" >> "$OUTPUT_FILE"

    echo "        </table>" >> "$OUTPUT_FILE"
fi

# Add 24h timeline visualization
cat >> "$OUTPUT_FILE" << 'HTMLTIMELINE'
        <h2><i class="fas fa-chart-gantt"></i> Pod Activity Timeline (24h)</h2>
        <div class="timeline-container">
            <div class="timeline-header">
                <span>24 hours ago</span>
                <span>Now</span>
            </div>
HTMLTIMELINE

# Generate timeline from event log and RunPod API
TIMELINE_OUTPUT=$(python3 << TIMELINE_SCRIPT
import json
import sys
import os
import subprocess
from datetime import datetime, timedelta
from collections import defaultdict

EVENT_LOG = "${EVENT_LOG}"
RUNPOD_API_KEY = "${RUNPOD_API_KEY}"

# Read event log
events = []
try:
    with open(EVENT_LOG, 'r') as f:
        for line in f:
            try:
                events.append(json.loads(line.strip()))
            except:
                pass
except:
    pass

now = datetime.utcnow()
start_time = now - timedelta(hours=24)

# Track pod activity from ALL event types (including "checked")
pod_activity = defaultdict(list)  # pod_id -> list of {time, status, provider}

# Get currently running pods from RunPod API
running_pods = {}
if RUNPOD_API_KEY:
    try:
        result = subprocess.run(
            ['curl', '-s', '-H', f'Authorization: Bearer {RUNPOD_API_KEY}',
             'https://rest.runpod.io/v1/pods'],
            capture_output=True, text=True, timeout=10
        )
        pods = json.loads(result.stdout)
        for pod in pods:
            pod_id = pod.get('id', '')
            created = pod.get('createdAt', '')
            name = pod.get('name', pod_id[:8])
            status = pod.get('desiredStatus', 'unknown')
            running_pods[pod_id] = {'name': name, 'created': created, 'status': status}
    except:
        pass

# Parse ALL events to build activity timeline
for event in sorted(events, key=lambda x: x.get('timestamp', '')):
    ts_str = event.get('timestamp', '')
    try:
        ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00').replace('+00:00', ''))
    except:
        continue

    pod_id = event.get('resource_id', '')
    if not pod_id:
        continue

    action = event.get('action', '')
    provider = event.get('provider', 'runpod')
    details = event.get('details', {})
    status = details.get('status', action)
    name = details.get('name', pod_id[:8])

    pod_activity[pod_id].append({
        'time': ts,
        'action': action,
        'status': status,
        'provider': provider,
        'name': name
    })

# Build sessions from activity data
sessions = {}
for pod_id, activities in pod_activity.items():
    if not activities:
        continue

    # Sort by time
    activities.sort(key=lambda x: x['time'])

    # Find first and last activity within 24h window
    first_in_window = None
    last_in_window = None
    provider = 'runpod'
    name = pod_id[:8]

    for act in activities:
        if act['time'] >= start_time:
            if first_in_window is None:
                first_in_window = act['time']
            last_in_window = act['time']
            provider = act['provider']
            name = act.get('name', pod_id[:8])

    if first_in_window:
        # Check if pod is still running
        is_running = pod_id in running_pods and running_pods[pod_id]['status'] == 'RUNNING'

        # If we have activity, estimate session duration
        # Use first seen as start, last seen (or now if running) as end
        sessions[pod_id] = {
            'start': first_in_window,
            'end': now if is_running else last_in_window + timedelta(minutes=15),  # Add buffer for last check
            'provider': provider,
            'name': name if name != pod_id[:8] else running_pods.get(pod_id, {}).get('name', pod_id[:8]),
            'running': is_running
        }

# Add currently running pods that might not be in event log
for pod_id, info in running_pods.items():
    if info['status'] != 'RUNNING':
        continue
    if pod_id not in sessions:
        try:
            # RunPod format: "2025-12-15 18:04:36.612 +0000 UTC"
            created_str = info['created'].replace(' UTC', '').replace(' +0000', '')
            # Now it's: "2025-12-15 18:04:36.612"
            created = datetime.strptime(created_str.split('.')[0], '%Y-%m-%d %H:%M:%S')
            if created < start_time:
                created = start_time
            sessions[pod_id] = {
                'start': created,
                'end': now,
                'provider': 'runpod',
                'name': info['name'],
                'running': True
            }
        except Exception as e:
            # Fallback: use start of window
            sessions[pod_id] = {
                'start': now - timedelta(minutes=5),
                'end': now,
                'provider': 'runpod',
                'name': info['name'],
                'running': True
            }

# Generate hour markers with UTC data attributes
print('<div class="timeline-hours">')
for i in range(0, 25, 6):
    t = start_time + timedelta(hours=i)
    iso_time = t.strftime('%Y-%m-%dT%H:%M:%SZ')
    display_time = t.strftime('%H:%M')
    print(f'<span class="tz-hour" data-utc="{iso_time}">{display_time}</span>')
print('</div>')

# Generate timeline bars
if sessions:
    # Summary stats
    total_pods = len(sessions)
    running_count = sum(1 for s in sessions.values() if s.get('running'))
    total_minutes = sum((s['end'] - s['start']).total_seconds() / 60 for s in sessions.values())

    print(f'<div style="background: #f0fdf4; border: 1px solid #86efac; border-radius: 8px; padding: 12px; margin-bottom: 16px; display: flex; gap: 24px; flex-wrap: wrap;">')
    print(f'    <div><strong style="color: #166534;">{total_pods}</strong> <span style="color: #4b5563;">pod(s) ran in last 24h</span></div>')
    print(f'    <div><strong style="color: #166534;">{int(total_minutes)}</strong> <span style="color: #4b5563;">total GPU minutes</span></div>')
    if running_count > 0:
        print(f'    <div><strong style="color: #059669;">{running_count}</strong> <span style="color: #4b5563;">currently running</span></div>')
    print(f'</div>')

    for pod_id, session in sorted(sessions.items(), key=lambda x: x[1]['start']):
        start = session['start']
        end = session['end'] or now
        provider = session['provider']
        name = session['name']
        is_running = session.get('running', False)

        # Calculate position as percentage of 24h window
        start_pct = max(0, (start - start_time).total_seconds() / (24 * 3600) * 100)
        end_pct = min(100, (end - start_time).total_seconds() / (24 * 3600) * 100)
        width_pct = end_pct - start_pct

        # Minimum 4% width so bars are always visible
        if width_pct < 4:
            width_pct = 4

        bar_class = 'running' if is_running else f'{provider} ended'
        duration = end - start
        duration_str = f'{int(duration.total_seconds() / 60)}m'
        if duration.total_seconds() >= 3600:
            duration_str = f'{duration.total_seconds() / 3600:.1f}h'

        # Time range for display with UTC data attributes
        start_iso = start.strftime('%Y-%m-%dT%H:%M:%SZ')
        end_iso = end.strftime('%Y-%m-%dT%H:%M:%SZ') if not is_running else ''
        start_display = start.strftime('%H:%M')
        end_display = end.strftime('%H:%M') if not is_running else 'now'
        status_indicator = ' <span style="color:#10b981;">● LIVE</span>' if is_running else ' <span style="color:#ef4444;">■ ended</span>'

        # Only show pod_id in parens if name is different (avoid "abc123 (abc123)")
        id_display = f' ({pod_id[:8]})' if name != pod_id[:8] and name != pod_id else ''

        # Build time range with data attributes for JS conversion
        if is_running:
            time_range_html = f'<span class="tz-time" data-utc="{start_iso}">{start_display}</span> - now'
        else:
            time_range_html = f'<span class="tz-time" data-utc="{start_iso}">{start_display}</span> - <span class="tz-time" data-utc="{end_iso}">{end_display}</span>'

        print(f'<div class="timeline-label" data-start="{start_iso}" data-end="{end_iso}">{name}{status_indicator} <span style="color:#6b7280; font-size: 11px;">{id_display} {time_range_html} ({duration_str})</span></div>')
        print(f'<div class="timeline-track">')
        print(f'    <div class="timeline-bar {bar_class}" style="left: {start_pct:.1f}%; width: {width_pct:.1f}%;" data-start="{start_iso}" data-end="{end_iso}" title="{name}: {start_display} - {end_display} ({duration_str})">')
        print(f'        {duration_str}')
        print(f'    </div>')
        print(f'</div>')
else:
    print('<div style="background: #f0fdf4; border: 1px solid #86efac; border-radius: 8px; padding: 12px; margin-bottom: 16px; text-align: center; color: #166534;">')
    print('    <i class="fas fa-check-circle"></i> No GPU pods running - $0.00/hr cost')
    print('</div>')
    print('<div class="no-data" style="margin: 20px 0;">No pod activity recorded in the last 24 hours</div>')

print('<div class="timeline-legend">')
print('    <div class="legend-item"><div style="width:4px;height:12px;background:#10b981;border-radius:2px;"></div> Started</div>')
print('    <div class="legend-item"><div style="width:4px;height:12px;background:#ef4444;border-radius:2px;"></div> Stopped</div>')
print('    <div class="legend-item"><div class="legend-dot runpod"></div> RunPod</div>')
print('    <div class="legend-item"><div class="legend-dot aws"></div> AWS</div>')
print('    <div class="legend-item"><div class="legend-dot running"></div> Running Now</div>')
print('</div>')
TIMELINE_SCRIPT
)
echo "$TIMELINE_OUTPUT" >> "$OUTPUT_FILE"

cat >> "$OUTPUT_FILE" << 'HTMLTIMELINEEND'
        </div>
HTMLTIMELINEEND

# Add event log
cat >> "$OUTPUT_FILE" << 'HTMLEVENTS'
        <h2><i class="fas fa-history"></i> Recent Events (24h)</h2>
        <div class="event-log">
HTMLEVENTS

if [ -f "$EVENT_LOG" ]; then
    # Get last 50 events, newest first
    tail -100 "$EVENT_LOG" 2>/dev/null | python3 -c "
import sys
import json

events = []
for line in sys.stdin:
    try:
        events.append(json.loads(line.strip()))
    except:
        pass

# Sort by timestamp descending
events.sort(key=lambda x: x.get('timestamp', ''), reverse=True)

for event in events[:50]:
    ts = event.get('timestamp', '')[:19].replace('T', ' ')
    provider = event.get('provider', 'unknown')
    action = event.get('action', 'unknown')
    resource = event.get('resource_id', 'unknown')
    details = event.get('details', {})

    provider_class = f'provider-{provider}'
    action_class = f'event-action-{action}'

    detail_str = ''
    if isinstance(details, dict):
        if 'reason' in details:
            detail_str = f\" - {details['reason']}\"
        elif 'status' in details:
            detail_str = f\" - {details['status']}\"

    print(f'''<div class=\"event-row\">
        <span class=\"event-time\">{ts}</span>
        <span class=\"provider-badge {provider_class}\">{provider.upper()}</span>
        <span class=\"{action_class}\">{action}</span>
        <code>{resource[:12]}</code>{detail_str}
    </div>''')
" >> "$OUTPUT_FILE"
else
    echo '<div class="no-data">No events logged yet</div>' >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" << 'HTMLSETTINGS'
        </div>

        <h2><i class="fas fa-cog"></i> Watchdog Settings</h2>
        <div class="card" style="margin-bottom: 20px;">
            <table class="settings-table" style="width: 100%; font-size: 14px;">
                <tr><td><i class="fas fa-clock"></i> Min Safe Runtime:</td><td>20 min (never kill during boot)</td></tr>
                <tr><td><i class="fas fa-hourglass-half"></i> Idle Threshold:</td><td>30 min (kill if idle longer)</td></tr>
                <tr><td><i class="fas fa-stopwatch"></i> Max Runtime:</td><td>2 hours (safety cap)</td></tr>
                <tr><td><i class="fas fa-tachometer-alt"></i> GPU Active Threshold:</td><td>&gt;5% utilization</td></tr>
            </table>
        </div>

        <h2><i class="fas fa-gavel"></i> Decision Rules</h2>
        <div class="card" style="margin-bottom: 20px; font-size: 13px; font-family: 'Monaco', 'Menlo', monospace;">
            <div style="padding: 6px 0;"><span class="rule-ok"><i class="fas fa-shield-alt"></i> Rule 1:</span> runtime &lt; 20 min → <strong>PROTECTED</strong> (boot window)</div>
            <div style="padding: 6px 0;"><span class="rule-kill"><i class="fas fa-skull"></i> Rule 2:</span> runtime &gt; 2 hours → <strong>KILL</strong> (safety cap)</div>
            <div style="padding: 6px 0;"><span class="rule-warn"><i class="fas fa-exclamation-triangle"></i> Rule 3:</span> boot stage 0 or 1 → <strong>WARN</strong> (still allocating/pulling)</div>
            <div style="padding: 6px 0;"><span class="rule-kill"><i class="fas fa-times-circle"></i> Rule 4:</span> container crashed &gt; 30 min → <strong>KILL</strong></div>
            <div style="padding: 6px 0;"><span class="rule-ok"><i class="fas fa-bolt"></i> Rule 5:</span> GPU &gt; 5% → <strong>ACTIVE</strong> (don't kill)</div>
            <div style="padding: 6px 0;"><span class="rule-kill"><i class="fas fa-bed"></i> Rule 6:</span> idle &gt; 30 min → <strong>KILL</strong> (forgotten)</div>
            <div style="padding: 6px 0;"><span class="rule-ok"><i class="fas fa-check-circle"></i> Rule 7:</span> otherwise → <strong>OK</strong> (grace period)</div>
        </div>

        <h2><i class="fas fa-terminal"></i> Setup &amp; Access</h2>
        <div class="card" style="margin-bottom: 20px; font-size: 13px;">
            <p style="margin-bottom: 8px;"><strong><i class="fas fa-play"></i> Run watchdog manually:</strong></p>
            <div class="code-block">./scripts/999-WATCHDOG--gpu-cost-guardian.sh --kill</div>

            <p style="margin-bottom: 8px; margin-top: 16px;"><strong><i class="fas fa-clock"></i> Setup cron (every 15 min):</strong></p>
            <div class="code-block" style="font-size: 11px;">*/15 * * * * /home/ubuntu/event-b/transcription-realtime-whisper-cognito-s3-lambda-ver4/scripts/999-WATCHDOG--gpu-cost-guardian.sh --kill --cron &gt;&gt; /var/log/gpu-watchdog.log 2&gt;&amp;1</div>

            <p style="margin-bottom: 8px; margin-top: 16px;"><strong><i class="fab fa-aws"></i> Enable S3 upload (add to .env):</strong></p>
            <div class="code-block">GPU_DASHBOARD_S3_BUCKET=s3://your-bucket/gpu-dashboard/</div>

            <p style="margin-bottom: 8px; margin-top: 16px;"><strong><i class="fas fa-desktop"></i> View dashboard locally:</strong></p>
            <div class="code-block">cd artifacts && python3 -m http.server 8080</div>
        </div>
HTMLSETTINGS

cat >> "$OUTPUT_FILE" << 'HTMLFOOTER'

        <p class="timestamp">
            <a href="https://github.com/davidbmar/whisperlive-runpod">
                <i class="fab fa-github"></i> GitHub: whisperlive-runpod
            </a>
        </p>
    </div>

    <script>
    (function() {
        // Dashboard date (UTC) from meta tag
        const dashboardDate = document.querySelector('meta[name="dashboard-date"]')?.content || new Date().toISOString().split('T')[0];
        const todayUTC = new Date().toISOString().split('T')[0];
        const pathname = window.location.pathname;
        const isLive = (dashboardDate === todayUTC) && (pathname.endsWith('index.html') || pathname.endsWith('/') || pathname.endsWith('/gpu-dashboard/'));

        // Timezone handling
        const tzSelect = document.getElementById('timezone');
        const savedTz = localStorage.getItem('gpu-dashboard-tz') || 'America/Chicago';
        tzSelect.value = savedTz;

        tzSelect.addEventListener('change', function() {
            localStorage.setItem('gpu-dashboard-tz', this.value);
            updateAllTimes(this.value);
        });

        // Format date for display
        function formatDateForTz(dateStr, tz) {
            try {
                const date = new Date(dateStr + 'T12:00:00Z');
                return date.toLocaleDateString('en-US', {
                    timeZone: tz,
                    weekday: 'short',
                    month: 'short',
                    day: 'numeric'
                });
            } catch (e) {
                return dateStr;
            }
        }

        // Format full datetime for display
        function formatDateTimeForTz(isoString, tz) {
            try {
                const date = new Date(isoString);
                return date.toLocaleString('en-US', {
                    timeZone: tz,
                    month: 'short',
                    day: 'numeric',
                    hour: '2-digit',
                    minute: '2-digit',
                    hour12: true
                });
            } catch (e) {
                return isoString;
            }
        }

        // Format just time (HH:MM) for timeline
        function formatTimeOnlyForTz(isoString, tz) {
            try {
                const date = new Date(isoString);
                return date.toLocaleTimeString('en-US', {
                    timeZone: tz,
                    hour: '2-digit',
                    minute: '2-digit',
                    hour12: false
                });
            } catch (e) {
                return isoString;
            }
        }

        // Get timezone abbreviation
        function getTzAbbr(tz) {
            try {
                const date = new Date();
                const parts = date.toLocaleString('en-US', { timeZone: tz, timeZoneName: 'short' }).split(' ');
                return parts[parts.length - 1];
            } catch (e) {
                return tz;
            }
        }

        // Update all displayed times
        function updateAllTimes(tz) {
            // Update header timestamp (full datetime)
            document.querySelectorAll('.local-time').forEach(el => {
                const utc = el.dataset.utc;
                if (utc) {
                    el.textContent = formatDateTimeForTz(utc, tz);
                }
            });

            // Update timeline hour markers (just HH:MM)
            document.querySelectorAll('.tz-hour').forEach(el => {
                const utc = el.dataset.utc;
                if (utc) {
                    el.textContent = formatTimeOnlyForTz(utc, tz);
                }
            });

            // Update timeline event times (just HH:MM)
            document.querySelectorAll('.tz-time').forEach(el => {
                const utc = el.dataset.utc;
                if (utc) {
                    el.textContent = formatTimeOnlyForTz(utc, tz);
                }
            });

            // Update date display
            document.getElementById('display-date').textContent = formatDateForTz(dashboardDate, tz);
            document.getElementById('display-date-label').textContent = getTzAbbr(tz);
        }

        // Date navigation
        function getAdjacentDate(dateStr, days) {
            const date = new Date(dateStr + 'T12:00:00Z');
            date.setUTCDate(date.getUTCDate() + days);
            return date.toISOString().split('T')[0];
        }

        const prevBtn = document.getElementById('prev-day');
        const nextBtn = document.getElementById('next-day');
        const prevDate = getAdjacentDate(dashboardDate, -1);
        const nextDate = getAdjacentDate(dashboardDate, 1);

        // Previous day - always enabled (archives may exist)
        prevBtn.href = prevDate + '.html';
        prevBtn.title = 'Previous day: ' + prevDate;

        // Next day - link to next date file, or index.html if next is today
        if (dashboardDate >= todayUTC) {
            // Viewing today or future - disable next
            nextBtn.classList.add('disabled');
            nextBtn.removeAttribute('href');
            nextBtn.title = 'No future data';
        } else if (nextDate === todayUTC) {
            // Next day is today - link to live dashboard
            nextBtn.href = 'index.html';
            nextBtn.title = 'Today (Live)';
        } else {
            // Next day is in the past - link to archive
            nextBtn.href = nextDate + '.html';
            nextBtn.title = 'Next day: ' + nextDate;
        }

        // Show live indicator
        const liveIndicator = document.getElementById('live-indicator');
        if (isLive) {
            liveIndicator.innerHTML = ' <span class="live-badge"><i class="fas fa-circle"></i> LIVE</span>';
        } else {
            liveIndicator.innerHTML = ' <span class="archive-badge"><i class="fas fa-archive"></i> Archive</span>';
        }

        // Initial time update
        updateAllTimes(savedTz);
    })();
    </script>
</body>
</html>
HTMLFOOTER

echo "Dashboard generated: $OUTPUT_FILE"

#===============================================================================
# Upload to S3 (if configured)
#===============================================================================

# Also save a daily archive locally
DAILY_ARCHIVE="$OUTPUT_DIR/gpu-dashboard-${TODAY}.html"
cp "$OUTPUT_FILE" "$DAILY_ARCHIVE"
echo "Daily archive: $DAILY_ARCHIVE"

if [ -n "$S3_BUCKET" ]; then
    echo "Uploading to S3: $S3_BUCKET"

    # Upload current dashboard as index.html
    aws s3 cp "$OUTPUT_FILE" "${S3_BUCKET}index.html" \
        --content-type "text/html" \
        --cache-control "max-age=60" \
        2>/dev/null

    # Also upload as today's dated archive
    aws s3 cp "$OUTPUT_FILE" "${S3_BUCKET}${TODAY}.html" \
        --content-type "text/html" \
        --cache-control "max-age=3600" \
        2>/dev/null

    if [ $? -eq 0 ]; then
        # Extract bucket name and region for URL
        BUCKET_NAME=$(echo "$S3_BUCKET" | sed 's|s3://||' | cut -d'/' -f1)
        echo "Dashboard URL: http://${BUCKET_NAME}.s3.amazonaws.com/index.html"
        echo "Daily archive: http://${BUCKET_NAME}.s3.amazonaws.com/${TODAY}.html"
    else
        echo "Warning: S3 upload failed"
    fi
else
    echo "S3 bucket not configured. Set GPU_DASHBOARD_S3_BUCKET in .env to enable upload."
    echo "View locally: file://$OUTPUT_FILE"
fi
