"""
CloudDrive Actions System.

Actions are pure transformations on session data.
An action takes a session as input and produces output files in S3.

Usage:
    from actions import get_action, list_actions

    # Run an action
    action = get_action('ai-analysis')()
    result = action.execute('users/123/audio/sessions/abc', {'force': True})

    # List available actions
    for action_info in list_actions():
        print(f"{action_info['name']}: {action_info['description']}")
"""

from .base import ActionBase, ActionResult, ActionError, DependencyError

# Import actions (lazy import to avoid circular dependencies)
_ACTIONS = None


def _load_actions():
    """Lazily load action classes."""
    global _ACTIONS
    if _ACTIONS is None:
        from .ai_analysis import AiAnalysisAction
        from .topics import TopicsAction
        from .transcribe import TranscribeAction
        from .diarize import DiarizeAction

        _ACTIONS = {
            'ai-analysis': AiAnalysisAction,
            'topics': TopicsAction,
            'transcribe': TranscribeAction,
            'diarize': DiarizeAction,
        }
    return _ACTIONS


def get_action(name: str):
    """
    Get action class by name.

    Args:
        name: Action name (e.g., 'ai-analysis', 'topics')

    Returns:
        Action class (not instance)

    Raises:
        ValueError: If action name is unknown
    """
    actions = _load_actions()
    if name not in actions:
        raise ValueError(f"Unknown action: {name}. Available: {list(actions.keys())}")
    return actions[name]


def list_actions():
    """
    List all available actions with metadata.

    Returns:
        List of dicts with action info:
        - name: Action identifier
        - description: What the action does
        - backend: 'api' (runs immediately) or 'gpu' (queued for batch)
        - requires: Input files needed
        - produces: Output files created
    """
    actions = _load_actions()
    return [
        {
            'name': action_cls.name,
            'description': action_cls.description,
            'backend': action_cls.backend,
            'requires': action_cls.requires,
            'produces': action_cls.produces
        }
        for action_cls in actions.values()
    ]


__all__ = [
    'ActionBase',
    'ActionResult',
    'ActionError',
    'DependencyError',
    'get_action',
    'list_actions',
]
