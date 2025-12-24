"""
Diarize Action.

GPU action that queues speaker diarization work for batch processing.
Uses pyannote on RunPod for speaker identification.

This action doesn't run diarization directly - it queues the work
and the batch scheduler picks it up.
"""

import logging
from typing import Dict

from .base import ActionBase, ActionResult

logger = logging.getLogger(__name__)


class DiarizeAction(ActionBase):
    """Queue speaker diarization for GPU batch processing."""

    name = 'diarize'
    description = 'Identify speakers using pyannote (GPU - queued for batch)'
    backend = 'gpu'  # Requires GPU
    requires = ['transcription-processed.json']  # Needs transcription first
    produces = ['transcription-diarized.json']

    def run(self, session_path: str, params: Dict) -> ActionResult:
        """
        Queue diarization work with speaker hints.

        GPU actions don't run immediately - they queue work in metadata.jobs
        for the batch scheduler to pick up.

        Args:
            session_path: S3 path like users/123/audio/sessions/abc
            params: Optional params:
                - force: bool - Re-diarize even if output exists
                - minSpeakers: int - Minimum number of speakers (hint)
                - maxSpeakers: int - Maximum number of speakers (hint)

        Returns:
            ActionResult with queued status
        """
        force = params.get('force', False)
        min_speakers = params.get('minSpeakers')
        max_speakers = params.get('maxSpeakers')

        # Check if output already exists
        if not force and self.file_exists(session_path, 'transcription-diarized.json'):
            logger.info("Diarization already exists. Use force=True to re-diarize.")
            return ActionResult(
                success=True,
                outputs=self.produces,
                duration_seconds=self.elapsed(),
                metadata={'skipped': True, 'reason': 'already exists'}
            )

        # If force=True, delete existing output to trigger re-processing
        if force:
            self.delete_if_exists(session_path, 'transcription-diarized.json')
            logger.info("Deleted existing diarization file for re-processing")

        # Also store diarization hints in metadata for the processor
        metadata = self.load_metadata(session_path)
        metadata['diarization'] = {
            'requested': True,
            'minSpeakers': min_speakers,
            'maxSpeakers': max_speakers,
        }
        self.save_metadata(session_path, metadata)

        # Queue the job
        job = self.queue_job(session_path, self.name, {
            'force': force,
            'minSpeakers': min_speakers,
            'maxSpeakers': max_speakers,
        })

        speaker_hint = ""
        if min_speakers or max_speakers:
            speaker_hint = f" (speakers: {min_speakers or '?'}-{max_speakers or '?'})"

        return ActionResult(
            success=True,
            outputs=[],  # No outputs yet - queued for batch
            duration_seconds=self.elapsed(),
            metadata={
                'status': 'queued',
                'job': job,
                'speakerHints': {
                    'min': min_speakers,
                    'max': max_speakers
                },
                'nextRun': f'Picked up by hourly batch scheduler{speaker_hint}'
            }
        )
