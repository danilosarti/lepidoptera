"""Type system layer.

FeatureType enumeration, domain validation, and value encoding/decoding.
See SPEC.md (repository root) section 3.1-3.2.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping

FEATURE_TYPES = ("continuous", "categorical", "ordinal")


def feature_types() -> tuple[str, ...]:
    """Return the allowed FeatureType values.

    Returns
    -------
    tuple[str, ...]
        ``("continuous", "categorical", "ordinal")``.
    """
    return FEATURE_TYPES


@dataclass(frozen=True)
class FeatureSpec:
    """A declared feature: name, type, domain, and optional metadata.

    See SPEC.md section 3.2. Construct via :func:`feature_spec` rather
    than instantiating directly.
    """

    name: str
    type: str
    domain: Mapping[str, Any]
    metadata: Mapping[str, Any] | None = field(default=None)

    @property
    def levels(self) -> list[Any] | None:
        """Convenience accessor for ``domain["levels"]`` (categorical/ordinal)."""
        if self.type in ("categorical", "ordinal"):
            return list(self.domain["levels"])
        return None


def feature_spec(
    name: str,
    type: str,
    domain: Mapping[str, Any],
    metadata: Mapping[str, Any] | None = None,
) -> FeatureSpec:
    """Declare a feature.

    Parameters
    ----------
    name:
        Unique identifier within the system.
    type:
        One of :func:`feature_types`.
    domain:
        For ``"continuous"``: ``{"min": ..., "max": ...}`` (either may be
        ``float("-inf")``/``float("inf")``). For ``"categorical"``/
        ``"ordinal"``: ``{"levels": [...]}``, where the order of
        ``levels`` matters for ``"ordinal"`` (it defines the scale order).
    metadata:
        Optional mapping, never interpreted by the core.

    Returns
    -------
    FeatureSpec

    Raises
    ------
    ValueError
        If ``name`` is empty, ``type`` is not a recognized FeatureType, or
        ``domain`` does not have the keys required for ``type``.
    """
    if not isinstance(name, str) or not name:
        raise ValueError("`name` must be a non-empty string.")

    if type not in FEATURE_TYPES:
        raise ValueError(
            f"Unknown feature type {type!r}. Must be one of {FEATURE_TYPES}."
        )

    if type == "continuous":
        if not isinstance(domain, Mapping) or not {"min", "max"} <= set(domain):
            raise ValueError(
                "`domain` for a continuous feature must be a mapping with "
                "'min' and 'max' keys, e.g. {'min': 0, 'max': float('inf')}."
            )
        if domain["min"] > domain["max"]:
            raise ValueError("`domain['min']` cannot be greater than `domain['max']`.")
    else:  # categorical / ordinal
        if not isinstance(domain, Mapping) or "levels" not in domain:
            raise ValueError(
                f"`domain` for a {type} feature must be a mapping with a "
                "'levels' key, e.g. {'levels': ['low', 'medium', 'high']}."
            )
        levels = list(domain["levels"])
        if len(levels) < 2:
            raise ValueError("`domain['levels']` must have at least 2 entries.")
        if len(set(levels)) != len(levels):
            raise ValueError("`domain['levels']` must not contain duplicates.")

    return FeatureSpec(name=name, type=type, domain=dict(domain), metadata=metadata)
