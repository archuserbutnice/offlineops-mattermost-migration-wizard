# Testing

## Local smoke checks

Run from the repository root:

```bash
bash -n mattermost-migration-wizard.sh
bash mattermost-migration-wizard.sh --self-test
bash tests/smoke-test.sh
```

If ShellCheck is installed:

```bash
shellcheck mattermost-migration-wizard.sh tests/smoke-test.sh
```

## What these checks prove

- `bash -n` checks shell syntax only.
- `--self-test` runs the script's built-in local sanity check.
- `tests/smoke-test.sh` runs syntax and the built-in self-test.

They do **not** simulate a real Mattermost installation, validate release availability, test a live download/checksum endpoint, test database compatibility, or prove a migration/rollback is safe. End-to-end testing must be performed on a disposable staging environment that matches the intended production layout.
