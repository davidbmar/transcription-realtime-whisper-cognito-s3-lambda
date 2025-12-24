"""
Transcribe Action.

GPU action that queues transcription work for batch processing.
Uses WhisperX on RunPod for actual transcription.

This action doesn't run the transcription directly - it queues the work
and the batch scheduler picks it up.
"""

import logging
from typing import Dict

from .base import ActionBase, ActionResult

logger = logging.getLogger(__name__)


class TranscribeAction(ActionBase):
    """Queue audio transcription for GPU batch processing."""

    name = 'transcribe'
    description = 'Transcribe audio using WhisperX (GPU - queued for batch)'
    backend = 'gpu'  # Requires GPU
    requires = []  # Audio chunks are detected by scanner
    produces = ['transcription.json', 'transcription-processed.json']

    def run(self, session_path: str, params: Dict) -> ActionResult:
        """
        Queue transcription work.

        GPU actions don't run immediately - they queue work in metadata.jobs
        for the batch scheduler to pick up.

        Args:
            session_path: S3 path like users/123/audio/sessions/abc
            params: Optional params:
                - force: bool - Re-transcribe even if output exists
                - language: str - Language code (default: auto-detect)

        Returns:
            ActionResult with queued status
        """
        force = params.get('force', False)

        # Check if output already exists
        if not force and self.file_exists(session_path, 'transcription.json'):
            logger.info("Transcription already exists. Use force=True to re-transcribe.")
            return ActionResult(
                success=True,
                outputs=self.produces,
                duration_seconds=self.elapsed(),
                metadata={'skipped': True, 'reason': 'already exists'}
            )

        # If force=True, delete existing output to trigger re-processing
        if force:
            self.delete_if_exists(session_path, 'transcription.json')
            self.delete_if_exists(session_path, 'transcription-processed.json')
            logger.info("Deleted existing transcription files for re-processing")

        # Queue the job
        job = self.queue_job(session_path, self.name, {
            'force': force,
            'language': params.get('language'),
        })

        return ActionResult(
            success=True,
            outputs=[],  # No outputs yet - queued for batch
            duration_seconds=self.elapsed(),
            metadata={
                'status': 'queued',
                'job': job,
                'nextRun': 'Picked up by hourly batch scheduler'
            }
        )
