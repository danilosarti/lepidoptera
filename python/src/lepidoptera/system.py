"""System builder layer.

Declaring features, edges, and mechanisms, and finalizing/validating a
System against the invariants in SPEC.md section 3.5.
"""

from __future__ import annotations

import copy
from typing import Sequence

from .graph import is_acyclic, topological_sort
from .mechanism import Mechanism
from .type_system import FeatureSpec


class System:
    """A system: features + dependency graph + mechanisms.

    See SPEC.md section 3.5. Build with ``add_feature``/``add_dependency``,
    then call ``finalize()`` before ``simulate()``/``propagate()``.
    Interventions operate on a derived copy (see intervention.py), never
    mutating the original.
    """

    def __init__(self) -> None:
        self.features: dict[str, FeatureSpec] = {}
        self.parents: dict[str, list[str]] = {}
        self.mechanisms: dict[str, Mechanism] = {}
        self.finalized: bool = False
        self.topo_order: list[str] = []

    def add_feature(self, spec: FeatureSpec) -> "System":
        """Add a feature to the system.

        Parameters
        ----------
        spec:
            A :class:`~lepidoptera.type_system.FeatureSpec`.

        Returns
        -------
        System
            ``self``, for chaining.
        """
        if self.finalized:
            raise RuntimeError("Cannot add features to an already-finalized system.")
        if spec.name in self.features:
            raise ValueError(f"Feature {spec.name!r} was already added.")
        self.features[spec.name] = spec
        return self

    def add_dependency(
        self, parents: Sequence[str], child: str, mechanism: Mechanism
    ) -> "System":
        """Add a dependency (edge set + mechanism) to the system.

        Parameters
        ----------
        parents:
            Names of parent features, in the same order used when the
            `mechanism` was built (empty sequence for a marginal/root
            mechanism).
        child:
            Name of the dependent feature. Must already exist (see
            ``add_feature``).
        mechanism:
            A :class:`~lepidoptera.mechanism.Mechanism`.

        Returns
        -------
        System
            ``self``, for chaining.
        """
        if self.finalized:
            raise RuntimeError(
                "Cannot add dependencies to an already-finalized system."
            )
        if child in self.mechanisms:
            raise ValueError(
                f"Feature {child!r} already has a mechanism; remove it first "
                "if you need to redefine it."
            )
        self.parents[child] = list(parents)
        self.mechanisms[child] = mechanism
        return self

    @property
    def edges(self) -> list[tuple[str, str]]:
        """All `(parent, child)` pairs declared via `add_dependency`."""
        return [
            (parent, child)
            for child, parents in self.parents.items()
            for parent in parents
        ]

    def finalize(self) -> "System":
        """Finalize and validate the system.

        Runs the invariants in SPEC.md section 3.5:

        1. every feature has exactly one mechanism;
        2. the dependency graph is acyclic;
        3. every edge references existing features;
        4. each mechanism's declared parent types match the actual types
           of the parents it was attached to;
        5. the mechanism's output type matches the feature's declared
           type.

        Returns
        -------
        System
            ``self``, marked finalized, ready for
            :func:`lepidoptera.simulate.simulate`.
        """
        if self.finalized:
            return self

        # Invariant 3: edges reference existing features.
        for child, parents in self.parents.items():
            if child not in self.features:
                raise ValueError(
                    f"add_dependency() declared child {child!r}, which was "
                    "never added via add_feature()."
                )
            for parent in parents:
                if parent not in self.features:
                    raise ValueError(
                        f"add_dependency() declared parent {parent!r} for "
                        f"child {child!r}, but {parent!r} was never added "
                        "via add_feature()."
                    )

        # Invariant 1: every feature has exactly one mechanism.
        missing = sorted(set(self.features) - set(self.mechanisms))
        if missing:
            raise ValueError(
                f"These features have no mechanism (call add_dependency, "
                f"with parents=[] for a root feature): {missing}."
            )

        # Invariant 4/5: type checks.
        for child, mechanism in self.mechanisms.items():
            declared_parents = self.parents[child]
            if len(mechanism.parent_types) != len(declared_parents):
                raise ValueError(
                    f"Mechanism for {child!r} declares "
                    f"{len(mechanism.parent_types)} parent type(s), but "
                    f"{len(declared_parents)} parent(s) were declared in "
                    "add_dependency()."
                )
            for parent, expected_type in zip(declared_parents, mechanism.parent_types):
                actual_type = self.features[parent].type
                if expected_type != actual_type:
                    raise ValueError(
                        f"Mechanism for {child!r} expects parent {parent!r} "
                        f"to be {expected_type!r}, but it is {actual_type!r}."
                    )
            child_type = self.features[child].type
            if mechanism.output_type != child_type:
                raise ValueError(
                    f"Mechanism for {child!r} produces {mechanism.output_type!r}, "
                    f"but {child!r} is declared as {child_type!r}."
                )

        # Invariant 2 + topological order (raises ValueError on a cycle).
        self.topo_order = topological_sort(list(self.features), self.edges)

        self.finalized = True
        return self

    def copy(self) -> "System":
        """A deep, independent copy (used internally by intervention.py)."""
        new = System()
        new.features = dict(self.features)
        new.parents = {k: list(v) for k, v in self.parents.items()}
        new.mechanisms = dict(self.mechanisms)
        new.finalized = False
        new.topo_order = []
        return new

    def plot_graph(self):
        """Plot the system's dependency graph. See plot.py."""
        from .plot import plot_graph

        return plot_graph(self)

    def to_json(self, path: str) -> None:
        """Export the system to JSON. See io.py."""
        from .io import export_system

        export_system(self, path, format="json")

    def to_yaml(self, path: str) -> None:
        """Export the system to YAML. See io.py."""
        from .io import export_system

        export_system(self, path, format="yaml")

    @classmethod
    def from_json(cls, path: str) -> "System":
        """Import a system from JSON. See io.py."""
        from .io import import_system

        return import_system(path, format="json")

    @classmethod
    def from_yaml(cls, path: str) -> "System":
        """Import a system from YAML. See io.py."""
        from .io import import_system

        return import_system(path, format="yaml")
