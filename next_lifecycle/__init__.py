"""REMNANODE NEXT lifecycle contracts.

Phase 1 is deliberately data-only and side-effect free.
"""

from .contracts import (
    IMAGE_PROVENANCE_V1,
    LIFECYCLE_JOURNAL_V1,
    MUTATION_ENVELOPE_V1,
    RELEASE_BINDING_V1,
    SECRET_PREFLIGHT_V1,
    VERIFY_RESULT_V1,
)

RUNTIME_CAPABILITIES = frozenset()

__all__ = [
    "IMAGE_PROVENANCE_V1",
    "LIFECYCLE_JOURNAL_V1",
    "MUTATION_ENVELOPE_V1",
    "RELEASE_BINDING_V1",
    "SECRET_PREFLIGHT_V1",
    "VERIFY_RESULT_V1",
    "RUNTIME_CAPABILITIES",
]
