# Contributing

Thanks for helping improve the OfflineOps Mattermost Migration Wizard.

## Before opening an issue or pull request

- Never include passwords, tokens, private URLs, customer data, database dumps, or unredacted logs.
- Describe the Mattermost version, OS release, install method, and service layout.
- For failures, include the exact command and a redacted error message.
- Do not submit changes that disable checksum verification or silently broaden destructive file operations.

## Pull request checklist

- [ ] Explain the problem and the proposed change.
- [ ] Update documentation and safety notes where needed.
- [ ] Run `bash -n mattermost-migration-wizard.sh`.
- [ ] Run `bash mattermost-migration-wizard.sh --self-test`.
- [ ] Run `bash tests/smoke-test.sh`.
- [ ] If available, run ShellCheck.
- [ ] State clearly whether the change was tested on a real staging server.

Keep changes small and reviewable. Do not claim end-to-end validation unless it was actually performed.
