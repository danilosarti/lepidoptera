"""Placeholder tests mapping to SPEC.md section 3.5 invariants and section 9
(parity test strategy). Fill in once System.add_feature()/add_dependency()/
finalize() are implemented.
"""

import pytest


@pytest.mark.skip(reason="Not implemented yet. See SPEC.md section 3.5, invariant 2.")
def test_system_with_cycle_is_rejected():
    pass


@pytest.mark.skip(reason="Not implemented yet. See SPEC.md section 3.5, invariant 1.")
def test_every_feature_ends_up_with_exactly_one_mechanism():
    pass


@pytest.mark.skip(reason="Not implemented yet. See SPEC.md section 3.5, invariant 3.")
def test_edges_referencing_unknown_features_are_rejected():
    pass
