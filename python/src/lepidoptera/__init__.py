"""lepidoptera: generic simulation engine for systems with mixed-type
dependent features.

See SPEC.md at the repository root for the full design specification:
data model (features, dependency graph, mechanisms, interventions),
supported type combinations, the copula mechanism (section 4.1), the
propagation engine, and the R/Python mirrored API (section 8).

Mirrors the R package's public API one-for-one (see ../R and ../NAMESPACE),
adapted to Python idiom (classes for System/Mechanism/Intervention rather
than R's functional S3 style).
"""

from .ai import llm_mechanism, learned_mechanism
from .copula import copula_mechanism, list_copula_families
from .intervention import (
    Intervention,
    SimulationResult,
    compare,
    do_distribution,
    do_fix,
    mechanism_override,
    propagate,
    shift,
)
from .io import export_system, import_system
from .mechanism import Mechanism, MechanismLibrary, mechanism_library, register_mechanism
from .plot import plot_graph
from .simulate import simulate
from .system import System
from .type_system import FeatureSpec, feature_spec, feature_types

__all__ = [
    "llm_mechanism",
    "learned_mechanism",
    "FeatureSpec",
    "feature_spec",
    "feature_types",
    "System",
    "Mechanism",
    "MechanismLibrary",
    "mechanism_library",
    "register_mechanism",
    "copula_mechanism",
    "list_copula_families",
    "simulate",
    "Intervention",
    "SimulationResult",
    "do_fix",
    "do_distribution",
    "shift",
    "mechanism_override",
    "propagate",
    "compare",
    "export_system",
    "import_system",
    "plot_graph",
]

__version__ = "0.0.0.dev0"
