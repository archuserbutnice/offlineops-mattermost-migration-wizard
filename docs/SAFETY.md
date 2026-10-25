# Safety and operational notes

This utility replaces Mattermost application files on a running server. Treat it as a maintenance operation, not as a harmless installer.

## Required precautions

1. Test on a disposable clone or staging server first.
2. Create a VM/storage snapshot using your platform's supported process.
3. Back up the database separately using the method appropriate to your database engine and deployment. Verify the backup.
4. Ensure you have console access and a maintenance window.
5. Review the script and upstream Mattermost documentation before every production run.
6. Confirm that the exact installed-version Team Edition archive exists and that the official checksum can be retrieved.

## Important limitations

- The wizard's optional application-state archive excludes the database.
- An application archive is not a complete system snapshot and does not guarantee rollback.
- Database schema changes, if triggered by application startup, may not be reversible simply by restoring application files.
- The script does not remove the existing APT package or repository.
- The script has not been end-to-end tested on every Mattermost version and installation method.

## Stop conditions

Stop if the version cannot be determined, the archive or official checksum cannot be verified, the archive layout is unexpected, or the service fails to start. Never disable checksum verification to force a run.

## After the conversion

Verify the login page, team/channel access, messages, file uploads, plugins, integrations, scheduled jobs, service logs, and your normal backup/monitoring process. Check your package/repository and future upgrade strategy before making additional changes.
