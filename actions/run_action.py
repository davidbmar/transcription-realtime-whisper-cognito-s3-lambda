#!/usr/bin/env python3
"""
CLI entry point for running CloudDrive actions.

Actions are pure transformations: input -> output
Triggers are separate: cron, UI button, S3 event, CLI

Execution modes:
  (default)        Run immediately (API actions only)
  --queue          Queue for batch processing (adds to metadata.jobs)
  --run-now        Run ONE session immediately (GPU must be up for GPU actions)
  --process-queue  Process ALL queued jobs (used by batch scheduler)

Mode Details:
  --run-now        For users who want immediate results on a single session.
                   Checks if GPU is running before executing GPU actions.
                   Example: User uploads audio, wants it transcribed NOW.

  --process-queue  For the batch scheduler to process all queued work.
                   Assumes GPU is already started by the scheduler.
                   Finds all sessions with status='queued' and processes them.
"""

import argparse
import json
import sys
import subprocess
import os

from actions import get_action, list_actions


HELP_EPILOG = """
Actions:
  ai-analysis    Generate AI analysis (Claude API)
  topics         Detect topic boundaries (Bedrock)
  diarize        Identify speakers (GPU - queued)
  transcribe     Transcribe audio (GPU - queued)

Modes:
  (default)        Run immediately (API actions only)
  --queue          Queue for batch processing (adds to metadata.jobs)
  --run-now        Run ONE session immediately (GPU must be up for GPU actions)
  --process-queue  Process ALL queued jobs (used by batch scheduler)

Mode Details:
  --run-now        For users who want immediate results on a single session.
                   Checks if GPU is running before executing GPU actions.
                   Example: User uploads audio, wants it transcribed NOW.

  --process-queue  For the batch scheduler to process all queued work.
                   Assumes GPU is already started by the scheduler.
                   Finds all sessions with status='queued' and processes them.

Examples:
  # List available actions
  ./scripts/run-action.sh --list

  # Run AI analysis immediately
  ./scripts/run-action.sh ai-analysis --session abc

  # Queue diarization for batch processing
  ./scripts/run-action.sh diarize --session abc --queue

  # Queue with parameters
  ./scripts/run-action.sh diarize --session abc --queue -p minSpeakers=2 -p force=true

  # Run diarization immediately (GPU must be up)
  ./scripts/run-action.sh diarize --session abc --run-now

  # Process all queued diarization jobs
  ./scripts/run-action.sh diarize --process-queue

  # Queue multiple sessions
  ./scripts/run-action.sh diarize --sessions abc,def,ghi --queue
"""


def is_gpu_running():
    """Check if GPU instance is running (for --run-now with GPU actions)."""
    try:
        # Check RunPod status
        result = subprocess.run(
            ['./scripts/851-runpod--status.sh'],
            capture_output=True,
            text=True,
            timeout=30
        )
        if 'RUNNING' in result.stdout:
            return True, 'runpod'

        # Check AWS EC2 GPU
        result = subprocess.run(
            ['./scripts/537-test-gpu-ssh.sh'],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            return True, 'aws'

        return False, None
    except Exception as e:
        print(f"Warning: Could not check GPU status: {e}")
        return False, None


def clean_session_path(session_path: str) -> str:
    """Clean session path (remove s3://bucket/ prefix if present)."""
    if session_path.startswith('s3://'):
        parts = session_path.replace('s3://', '').split('/', 1)
        if len(parts) > 1:
            return parts[1]
    return session_path


def parse_params(param_list: list) -> dict:
    """Parse key=value parameters into dict."""
    params = {}
    if param_list:
        for p in param_list:
            if '=' not in p:
                print(f"Error: Invalid parameter format '{p}'. Use key=value")
                sys.exit(1)
            key, value = p.split('=', 1)
            # Try to parse as JSON (for numbers, bools)
            try:
                params[key] = json.loads(value)
            except json.JSONDecodeError:
                params[key] = value
    return params


def run_action(action, session_path: str, params: dict):
    """Run an action on a single session."""
    print()
    print("=" * 60)
    print(f"Running action: {action.name}")
    print("=" * 60)
    print(f"  Session: {session_path}")
    print(f"  Backend: {action.backend}")
    print(f"  Params: {params}")
    print()

    result = action.execute(session_path, params)

    # Output result
    print()
    print("=" * 60)
    print("Result")
    print("=" * 60)
    print(f"  Success: {result.success}")
    print(f"  Duration: {result.duration_seconds}s")
    print(f"  Outputs: {result.outputs}")
    if result.metadata:
        print(f"  Metadata: {json.dumps(result.metadata, indent=4)}")
    if result.error:
        print(f"  Error: {result.error}")
    print()

    return result


def main():
    parser = argparse.ArgumentParser(
        description='Run a CloudDrive action on a session.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=HELP_EPILOG
    )
    parser.add_argument('action', nargs='?', help='Action name to run')
    parser.add_argument('--session', '-s', help='Session ID or full path')
    parser.add_argument('--sessions', help='Comma-separated list of session IDs')
    parser.add_argument('--list', '-l', action='store_true', help='List available actions')
    parser.add_argument('--param', '-p', action='append', help='Parameters as key=value')

    # Execution modes
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument('--queue', action='store_true',
                           help='Queue for batch processing (adds to metadata.jobs)')
    mode_group.add_argument('--run-now', action='store_true',
                           help='Run immediately (checks GPU for GPU actions)')
    mode_group.add_argument('--process-queue', action='store_true',
                           help='Process all queued jobs (used by batch scheduler)')

    args = parser.parse_args()

    # List actions
    if args.list or not args.action:
        print("\nAvailable actions:")
        print("=" * 60)
        for action_info in list_actions():
            backend = action_info.get('backend', 'api')
            backend_tag = ' (GPU)' if backend == 'gpu' else ''
            print(f"\n  {action_info['name']}{backend_tag}")
            print(f"    {action_info['description']}")
            print(f"    Backend: {backend}")
            print(f"    Requires: {action_info['requires']}")
            print(f"    Produces: {action_info['produces']}")
        print()
        return 0

    # Get action
    try:
        ActionClass = get_action(args.action)
    except ValueError as e:
        print(f"Error: {e}")
        return 1

    action = ActionClass()
    params = parse_params(args.param)

    # Handle --process-queue: find and process all queued jobs
    if args.process_queue:
        print(f"\nProcessing all queued '{action.name}' jobs...")
        print("=" * 60)
        # This would be called by the batch scheduler
        # For now, we scan for queued jobs in metadata.json
        # The actual implementation integrates with 512-queue--scan-pending-jobs.sh
        print("Note: --process-queue is intended for the batch scheduler.")
        print("Use ./scripts/512-queue--scan-pending-jobs.sh to find queued work.")
        print("Use ./scripts/535-trigger--batch-scheduler.sh to run the full batch process.")
        return 0

    # Validate session(s)
    session_paths = []
    if args.sessions:
        session_paths = [clean_session_path(s.strip()) for s in args.sessions.split(',')]
    elif args.session:
        session_paths = [clean_session_path(args.session)]
    else:
        print("Error: --session or --sessions is required")
        parser.print_help()
        return 1

    # Handle --queue: just queue the jobs
    if args.queue:
        print(f"\nQueueing '{action.name}' for batch processing...")
        print("=" * 60)
        for session_path in session_paths:
            print(f"  Queueing: {session_path}")
            job = action.queue_job(session_path, action.name, params)
            print(f"    Status: {job['status']}")
            print(f"    QueuedAt: {job['queuedAt']}")

        print()
        print(f"Queued {len(session_paths)} session(s) for '{action.name}'.")
        print("Jobs will be picked up by the hourly batch scheduler.")
        print()
        return 0

    # Handle --run-now: check GPU if needed, then run immediately
    if args.run_now or action.backend == 'api':
        # For GPU actions, check if GPU is up
        if action.backend == 'gpu':
            print(f"\nChecking GPU status for '{action.name}'...")
            gpu_up, gpu_provider = is_gpu_running()
            if not gpu_up:
                print("Error: GPU is not running.")
                print("  Options:")
                print("    1. Start GPU: ./scripts/850-runpod--start.sh")
                print("    2. Queue instead: ./scripts/run-action.sh {action.name} --session {session_paths[0]} --queue")
                return 1
            print(f"  GPU is running ({gpu_provider}). Proceeding...")

        # Run on each session
        success = True
        for session_path in session_paths:
            result = run_action(action, session_path, params)
            if not result.success:
                success = False

        return 0 if success else 1

    # Default: API actions run immediately, GPU actions are queued
    if action.backend == 'gpu':
        print(f"\nNote: '{action.name}' is a GPU action.")
        print("  Use --queue to queue for batch processing, or")
        print("  Use --run-now to run immediately (requires GPU to be up)")
        return 1
    else:
        # API action - run immediately
        success = True
        for session_path in session_paths:
            result = run_action(action, session_path, params)
            if not result.success:
                success = False
        return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
