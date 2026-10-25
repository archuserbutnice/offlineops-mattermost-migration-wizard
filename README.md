<div align="center">

# OfflineOps · Mattermost Migration Wizard

**A guided, same-version conversion from Mattermost Entry to Team Edition on Ubuntu/systemd.**

[![Bash syntax](https://github.com/OWNER/REPO/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/REPO/actions/workflows/ci.yml)
[![Shell](https://img.shields.io/badge/shell-Bash-121011?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%20%2F%20systemd-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

*Detect · Verify · Preserve · Convert · Validate*

</div>

---

> [!CAUTION]
> **This changes application files on a live Mattermost server.** Test on a disposable/staging instance first. Take a VM/storage snapshot and a separate, verified database backup before production use. The wizard's optional archive is **not** a database backup and is **not** a complete rollback mechanism.

## What it does

- Detects the installed Mattermost version from the local installation.
- Targets the **same version** for Team Edition rather than intentionally upgrading Mattermost.
- Downloads the corresponding Linux archive and requires an official SHA-256 checksum before proceeding.
- Validates archive paths before extraction to reduce path-traversal risk.
- Offers an optional backup of selected application state; you can skip it after an explicit confirmation.
- Preserves the existing systemd service and system account instead of automatically removing packages.
- Shows a guided, numbered workflow with download progress.
- Checks that the service starts after file replacement.

## What it does not do

- It does **not** back up or restore the database.
- It does **not** create a VM/storage snapshot.
- It does **not** guarantee rollback if the application replacement or startup fails.
- It does **not** remove the existing APT package/repository.
- It does **not** upgrade Mattermost or PostgreSQL intentionally. Availability of an exact-version Team Edition archive is a prerequisite.
- It has not been validated against every Mattermost release, Ubuntu release, package layout, plugin, or deployment topology.

## Before you start

Confirm all of the following:

- [ ] You have a recent VM/storage snapshot and a tested database backup.
- [ ] You have console or out-of-band access if the web service fails.
- [ ] Your deployment uses the expected Linux installation layout and a `mattermost` systemd service.
- [ ] You have reviewed the script and verified the official archive/checksum availability for your installed version.
- [ ] You have tested the procedure in staging with your actual plugins and integrations.
- [ ] You have an approved maintenance window and a way to restore service.

**Do not use this wizard as a substitute for Mattermost's current official migration guidance.** Check the upstream documentation and licensing/edition requirements for your deployment before proceeding.

## Quick start

Download the script from this repository, inspect it, then run:

```bash
chmod +x mattermost-migration-wizard.sh
sudo ./mattermost-migration-wizard.sh
```

Run the built-in local self-test without starting a migration:

```bash
bash mattermost-migration-wizard.sh --self-test
```

The self-test is a small local sanity check. It does not contact Mattermost, download an archive, test your server, or perform a migration.

## Typical workflow

1. Check prerequisites and identify the installation/version.
2. Review the detected target version and installation details.
3. Confirm the exact-version Team Edition archive and checksum are available.
4. Choose whether to create the optional selected-state archive.
5. Download and verify the archive.
6. Validate the archive listing and extract it to a temporary directory.
7. Confirm the application-file replacement and allow the service to restart.
8. Check service status and manually validate the web UI, plugins, integrations, and logs.

## Backup scope

When selected, the optional backup is intended to archive selected application state such as configuration, data, logs, and plugins. **It excludes the database.** Review the exact paths and exclusions in the script before relying on it. Store backups securely and verify that they can be read.

Skipping the optional archive means you should have a separately tested snapshot/restore path. The script does not promise automatic rollback.

## Compatibility and requirements

The script expects a Linux host with Bash, systemd, and the utilities checked by the script, including `curl`, `tar`, `sha256sum`, and Python 3. It must run with root privileges. The current implementation is aimed at an Ubuntu/systemd installation using the expected Mattermost directory and service layout; do not assume it supports containers, Kubernetes, non-systemd hosts, custom layouts, or every package installation method.

## Troubleshooting

Check the service and recent logs:

```bash
sudo systemctl status mattermost --no-pager --full
sudo journalctl -u mattermost -n 150 --no-pager
```

Inspect the installed version and the installation directory configured in the script. If download or checksum verification fails, stop; do not bypass verification or use an archive from an untrusted mirror. If the service does not start, preserve logs and the optional archive, and restore from your separately tested snapshot/backup procedure.

## Repository layout

```text
.
├── .github/
│   ├── ISSUE_TEMPLATE/
│   └── workflows/ci.yml
├── docs/
│   ├── SAFETY.md
│   └── TESTING.md
├── tests/
│   └── smoke-test.sh
├── LICENSE
├── CONTRIBUTING.md
├── SECURITY.md
├── CHANGELOG.md
└── mattermost-migration-wizard.sh
```

## Credits

Maintained under the **OfflineOps** branding. The terminal banner credits `kooroshahmadi` and links to [offlineops.ir](https://offlineops.ir). Mattermost is a trademark of its respective owner; this project is an independent community utility and is not affiliated with or endorsed by Mattermost, Inc.

---

<div align="center">

**Review first. Snapshot first. Verify after.**

</div>
