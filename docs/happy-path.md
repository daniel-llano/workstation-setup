# Workstation Setup happy path

There is no web UI. The check is the script itself.

1. `.\dev-setup.cmd -List` prints every step id.
2. `.\dev-setup.cmd -DryRun -Only battery_charge_limit` reports a dry-run and does not change the machine.
3. A missing `.env` must not abort that dry-run.

The capture in [docs/screenshots](screenshots) is the `-List` output.
