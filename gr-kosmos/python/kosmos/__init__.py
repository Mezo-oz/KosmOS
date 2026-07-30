# SPDX-License-Identifier: GPL-3.0-or-later
"""
gr-kosmos — out-of-tree GNU Radio blocks for KosmOS.

Instrumentation and protocol blocks that the GNU Radio catalog has no part for.
See ../../README.md for the rule about when a custom block is justified.
"""

from .discontinuity_probe import discontinuity_probe

__all__ = ["discontinuity_probe"]
