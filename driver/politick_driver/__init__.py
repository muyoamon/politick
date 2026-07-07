"""Persona driver for the politick kernel.

The kernel is the source of truth; this package only reads its NDJSON
output and appends input entries to the log. All state is re-derivable
from the log — the driver holds none of its own.
"""
