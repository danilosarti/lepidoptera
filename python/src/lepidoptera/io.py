"""I/O / serialization layer.

Exporting and importing a System (structure only, no simulated data) in a
format shared with the R implementation, to serve as the R/Python parity
contract. See SPEC.md section 7, layer 7.

Serialized shape::

    {
      "features": [{"name", "type", "domain", "metadata"}, ...],
      "dependencies": [
        {"child": ..., "parents": [...], "mechanism": {"factory": ..., "kwargs": {...}}},
        ...
      ]
    }

Only mechanisms built from a pre-built factory (i.e. with a non-``None``
``Mechanism.spec``) are serializable — mechanisms created via
``register_mechanism`` carry an arbitrary Python closure and have no
``spec``, so exporting a system that uses one raises a clear error.
"""

from __future__ import annotations

import json
from typing import Any, Literal

from .mechanism import mechanism_from_spec
from .system import System
from .type_system import feature_spec

Format = Literal["json", "yaml"]


def _system_to_dict(system: System) -> dict[str, Any]:
    unserializable = [
        name for name, mech in system.mechanisms.items() if mech.spec is None
    ]
    if unserializable:
        raise ValueError(
            "Cannot serialize a system that uses custom (register_mechanism) "
            f"mechanisms for these features: {sorted(unserializable)}. Only "
            "pre-built mechanism_library factories are serializable."
        )

    return {
        "features": [
            {
                "name": spec.name,
                "type": spec.type,
                "domain": dict(spec.domain),
                "metadata": dict(spec.metadata) if spec.metadata is not None else None,
            }
            for spec in system.features.values()
        ],
        "dependencies": [
            {
                "child": child,
                "parents": list(system.parents[child]),
                "mechanism": dict(system.mechanisms[child].spec),
            }
            for child in system.features
            if child in system.mechanisms
        ],
    }


def _system_from_dict(data: dict[str, Any]) -> System:
    system = System()
    for feature in data["features"]:
        system.add_feature(
            feature_spec(
                name=feature["name"],
                type=feature["type"],
                domain=feature["domain"],
                metadata=feature.get("metadata"),
            )
        )
    for dependency in data["dependencies"]:
        mechanism = mechanism_from_spec(dependency["mechanism"])
        system.add_dependency(
            parents=dependency["parents"],
            child=dependency["child"],
            mechanism=mechanism,
        )
    return system


def export_system(system: System, path: str, format: Format = "json") -> None:
    """Export a system to JSON or YAML.

    Parameters
    ----------
    system:
        A :class:`~lepidoptera.system.System` (need not be finalized).
    path:
        Output file path.
    format:
        ``"json"`` or ``"yaml"``.
    """
    data = _system_to_dict(system)
    if format == "json":
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, default=_json_default)
    elif format == "yaml":
        try:
            import yaml
        except ImportError as exc:
            raise ImportError(
                "export_system(format='yaml') requires PyYAML: pip install pyyaml"
            ) from exc
        with open(path, "w", encoding="utf-8") as fh:
            yaml.safe_dump(data, fh, sort_keys=False)
    else:
        raise ValueError("`format` must be 'json' or 'yaml'.")


def import_system(path: str, format: Format = "json") -> System:
    """Import a system from JSON or YAML.

    Parameters
    ----------
    path:
        Input file path.
    format:
        ``"json"`` or ``"yaml"``.

    Returns
    -------
    System
        Not yet finalized — call ``.finalize()`` before simulating.
    """
    if format == "json":
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    elif format == "yaml":
        try:
            import yaml
        except ImportError as exc:
            raise ImportError(
                "import_system(format='yaml') requires PyYAML: pip install pyyaml"
            ) from exc
        with open(path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    else:
        raise ValueError("`format` must be 'json' or 'yaml'.")

    return _system_from_dict(data)


def _json_default(obj: Any) -> Any:
    if isinstance(obj, float) and obj == float("inf"):
        return "Infinity"
    if isinstance(obj, float) and obj == float("-inf"):
        return "-Infinity"
    raise TypeError(f"Object of type {type(obj)} is not JSON serializable.")
