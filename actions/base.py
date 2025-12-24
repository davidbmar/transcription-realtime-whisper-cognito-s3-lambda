"""
Base class for all CloudDrive actions.
Provides S3 helpers, logging, timing, and dependency validation.
"""

import json
import time
import os
import logging
from dataclasses import dataclass, field
from typing import List, Dict, Any, Optional
from abc import ABC, abstractmethod

import boto3

from .config import AWS_REGION, S3_BUCKET

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


@dataclass
class ActionResult:
    """Result returned by every action."""
    success: bool
    outputs: List[str] = field(default_factory=list)  # Files created (relative to session)
    duration_seconds: float = 0.0
    metadata: Optional[Dict] = None  # Action-specific data
    error: Optional[str] = None      # Error message if failed


class ActionError(Exception):
    """Raised when an action fails."""
    pass


class DependencyError(ActionError):
    """Raised when required input files are missing."""
    pass


class ActionBase(ABC):
    """
    Base class for all actions. Subclasses must implement:
    - name: str - Unique action identifier
    - run(session_path, params) -> ActionResult
    """

    # Class attributes (override in subclass)
    name: str = ''
    description: str = ''
    backend: str = 'api'          # 'api' (runs immediately) or 'gpu' (queued for batch)
    requires: List[str] = []      # Files that must exist before running
    produces: List[str] = []      # Files this action creates

    def __init__(self):
        self._start_time = None
        self._s3 = boto3.client('s3', region_name=AWS_REGION)
        self._bucket = S3_BUCKET

    # ─────────────────────────────────────────────────────────────────
    # S3 Helpers
    # ─────────────────────────────────────────────────────────────────

    def load_file(self, session_path: str, filename: str) -> Dict:
        """Load JSON file from S3 session folder."""
        key = f"{session_path}/{filename}"
        try:
            logger.info(f"Loading s3://{self._bucket}/{key}")
            response = self._s3.get_object(Bucket=self._bucket, Key=key)
            return json.loads(response['Body'].read().decode('utf-8'))
        except self._s3.exceptions.NoSuchKey:
            raise FileNotFoundError(f"File not found: s3://{self._bucket}/{key}")

    def save_file(self, session_path: str, filename: str, data: Dict) -> str:
        """Save JSON data to S3 session folder."""
        key = f"{session_path}/{filename}"
        logger.info(f"Saving to s3://{self._bucket}/{key}")
        self._s3.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=json.dumps(data, indent=2).encode('utf-8'),
            ContentType='application/json',
            Metadata={
                'generated-by': f'action-{self.name}',
                'generated-at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
            }
        )
        return f"s3://{self._bucket}/{key}"

    def file_exists(self, session_path: str, filename: str) -> bool:
        """Check if file exists in S3."""
        key = f"{session_path}/{filename}"
        try:
            self._s3.head_object(Bucket=self._bucket, Key=key)
            return True
        except:
            return False

    def delete_if_exists(self, session_path: str, filename: str) -> bool:
        """Delete file from S3 if it exists. Returns True if deleted."""
        key = f"{session_path}/{filename}"
        try:
            self._s3.head_object(Bucket=self._bucket, Key=key)
            logger.info(f"Deleting s3://{self._bucket}/{key}")
            self._s3.delete_object(Bucket=self._bucket, Key=key)
            return True
        except:
            return False

    def list_files(self, session_path: str, prefix: str = '') -> List[str]:
        """List files in session folder with optional prefix."""
        full_prefix = f"{session_path}/{prefix}" if prefix else session_path
        response = self._s3.list_objects_v2(
            Bucket=self._bucket,
            Prefix=full_prefix
        )
        return [obj['Key'].replace(f"{session_path}/", '')
                for obj in response.get('Contents', [])]

    # ─────────────────────────────────────────────────────────────────
    # Metadata & Queue Helpers
    # ─────────────────────────────────────────────────────────────────

    def load_metadata(self, session_path: str) -> Dict:
        """Load metadata.json from session folder."""
        try:
            return self.load_file(session_path, 'metadata.json')
        except FileNotFoundError:
            return {}

    def save_metadata(self, session_path: str, metadata: Dict) -> str:
        """Save metadata.json to session folder."""
        return self.save_file(session_path, 'metadata.json', metadata)

    def queue_job(self, session_path: str, action_name: str, params: Dict = None) -> Dict:
        """
        Add a job to the session's queue in metadata.json.

        Args:
            session_path: S3 path like users/123/audio/sessions/abc
            action_name: Name of the action to queue
            params: Optional parameters for the action

        Returns:
            The job entry that was created
        """
        import time

        metadata = self.load_metadata(session_path)
        metadata['jobs'] = metadata.get('jobs', {})

        job = {
            'status': 'queued',
            'queuedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'params': params or {}
        }

        metadata['jobs'][action_name] = job
        self.save_metadata(session_path, metadata)

        logger.info(f"Queued job '{action_name}' for {session_path}")
        return job

    def get_job_status(self, session_path: str, action_name: str) -> Optional[Dict]:
        """Get status of a job from metadata.json."""
        metadata = self.load_metadata(session_path)
        return metadata.get('jobs', {}).get(action_name)

    def update_job_status(self, session_path: str, action_name: str, status: str, **kwargs) -> Dict:
        """
        Update job status in metadata.json.

        Args:
            session_path: S3 path
            action_name: Name of the action
            status: New status (queued, running, completed, failed)
            **kwargs: Additional fields to set (error, startedAt, completedAt)

        Returns:
            The updated job entry
        """
        import time

        metadata = self.load_metadata(session_path)
        metadata['jobs'] = metadata.get('jobs', {})

        job = metadata['jobs'].get(action_name, {})
        job['status'] = status

        # Add timestamp based on status
        if status == 'running':
            job['startedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        elif status in ('completed', 'failed'):
            job['completedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

        # Add any extra fields
        job.update(kwargs)

        metadata['jobs'][action_name] = job
        self.save_metadata(session_path, metadata)

        logger.info(f"Updated job '{action_name}' status to '{status}' for {session_path}")
        return job

    # ─────────────────────────────────────────────────────────────────
    # Timing
    # ─────────────────────────────────────────────────────────────────

    def start_timer(self):
        """Start the action timer."""
        self._start_time = time.time()

    def elapsed(self) -> float:
        """Get elapsed time since start_timer()."""
        if self._start_time is None:
            return 0.0
        return round(time.time() - self._start_time, 2)

    # ─────────────────────────────────────────────────────────────────
    # Validation
    # ─────────────────────────────────────────────────────────────────

    def validate_dependencies(self, session_path: str):
        """Check that all required files exist. Raises DependencyError if not."""
        missing = []
        for required_file in self.requires:
            if not self.file_exists(session_path, required_file):
                missing.append(required_file)

        if missing:
            raise DependencyError(
                f"Action '{self.name}' requires files that don't exist: {missing}. "
                f"Run the actions that produce these files first."
            )

    # ─────────────────────────────────────────────────────────────────
    # Main Entry Point
    # ─────────────────────────────────────────────────────────────────

    def execute(self, session_path: str, params: Dict = None) -> ActionResult:
        """
        Execute the action with validation and error handling.
        This is the public method - calls the subclass run() method.
        """
        self.start_timer()

        try:
            # Validate dependencies
            self.validate_dependencies(session_path)

            # Run the actual action logic
            result = self.run(session_path, params or {})

            # Ensure proper return type
            if not isinstance(result, ActionResult):
                result = ActionResult(
                    success=True,
                    outputs=self.produces,
                    duration_seconds=self.elapsed()
                )

            return result

        except DependencyError as e:
            logger.error(f"Dependency error: {e}")
            return ActionResult(
                success=False,
                outputs=[],
                duration_seconds=self.elapsed(),
                error=str(e)
            )
        except Exception as e:
            logger.error(f"Action failed: {type(e).__name__}: {e}")
            return ActionResult(
                success=False,
                outputs=[],
                duration_seconds=self.elapsed(),
                error=f"{type(e).__name__}: {str(e)}"
            )

    @abstractmethod
    def run(self, session_path: str, params: Dict) -> ActionResult:
        """
        Execute the action logic. Must be implemented by subclass.

        Args:
            session_path: S3 path like "users/123/audio/sessions/abc"
            params: Action-specific parameters

        Returns:
            ActionResult with success status and output files
        """
        pass
