"""Simulation engine layer.

Generating units and populations from a finalized System. See SPEC.md
section 5.
"""

from __future__ import annotations

from typing import Optional

import numpy as np
import pandas as pd

from .system import System


def _unit_rngs(n: int, seed: Optional[int]) -> list[np.random.Generator]:
    """One independent RNG stream per unit, derived from a single seed.

    This is what makes "partial" resampling in propagate() reproducible
    and paired with the baseline: regenerating only a subset of units (or
    only a subset of features for a given unit) does not change the
    random draws used for the rest, because each unit's stream is
    independent of how many other units are generated. See SPEC.md
    section 5.1.
    """
    seed_seq = np.random.SeedSequence(seed)
    return [np.random.default_rng(s) for s in seed_seq.spawn(n)]


def _generate_unit(system: System, rng: np.random.Generator) -> dict:
    row: dict = {}
    for name in system.topo_order:
        mechanism = system.mechanisms[name]
        parent_values = {p: row[p] for p in system.parents[name]}
        row[name] = mechanism.sample(parent_values, rng)
    return row


def _to_typed_frame(system: System, rows: list[dict]) -> pd.DataFrame:
    df = pd.DataFrame(rows, columns=list(system.topo_order))
    for name, spec in system.features.items():
        if spec.type == "categorical":
            df[name] = pd.Categorical(df[name], categories=spec.levels, ordered=False)
        elif spec.type == "ordinal":
            df[name] = pd.Categorical(df[name], categories=spec.levels, ordered=True)
        else:
            df[name] = df[name].astype(float)
    return df


def simulate(system: System, n: int, seed: Optional[int] = None) -> pd.DataFrame:
    """Simulate a population from a system.

    Parameters
    ----------
    system:
        A finalized :class:`~lepidoptera.system.System` (see
        ``System.finalize()``).
    n:
        Number of units to generate.
    seed:
        Optional seed for reproducibility.

    Returns
    -------
    pandas.DataFrame
        One row per unit, one column per feature, typed according to each
        feature's FeatureType (categorical/ordinal columns are
        ``pandas.Categorical``).
    """
    if not system.finalized:
        raise RuntimeError("System must be finalized (system.finalize()) before simulate().")
    if n < 1:
        raise ValueError("`n` must be a positive integer.")

    rngs = _unit_rngs(n, seed)
    rows = [_generate_unit(system, rng) for rng in rngs]
    return _to_typed_frame(system, rows)
