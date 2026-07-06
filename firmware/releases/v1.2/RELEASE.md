# T1000-E tracker firmware — v1.2

- **Date:** 2026-07-06
- **Vendor base:** meshtastic/firmware `v2.7.15.567b8ea` + patch + drop-ins
- **New since v1.1 (accuracy pack):**
  - **GST-backed accuracy**: $PAIR062,8,1 enables the receiver's own per-fix error statistics;
    the payload hacc byte now carries the GNSS's real 1-sigma horizontal error (HDOP heuristic
    kept as fallback). Verified: GST ACK 0, sentence stream 4/fix.
  - **Elevation mask** as a BLE-configurable knob (settings v2, wire byte [7], default 10°) —
    $PAIR072 ACK 0 on our unit despite the spec's BA-lineage "unsupported" note.
  - **Boot diagnostics**: AIC status (confirmed ON), EASY query (**unsupported on this build —
    ACK 3**; EPO injection remains the TTFF option), jamming-detect events enabled.
  - Learned: nav mode 7 (Swimming) is rejected by our unit (ACK 4) — app annotated.

Flash: `tools/flash_t1000e.sh <flavor> [port|role]`. Verify: `shasum -a 256 -c SHA256SUMS`.
