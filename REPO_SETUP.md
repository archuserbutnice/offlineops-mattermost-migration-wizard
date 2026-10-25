# Repository publishing checklist

This file is for the repository owner; remove it after setup if you do not want it public.

## Suggested repository metadata

- **Name:** `offlineops-mattermost-migration-wizard`
- **Description:** Guided same-version Mattermost Entry → Team Edition conversion wizard for Ubuntu/systemd.
- **Website:** `https://offlineops.ir`
- **Topics:** `mattermost`, `bash`, `ubuntu`, `systemd`, `migration`, `devops`, `offlineops`
- **Visibility:** Public only if you intend to maintain and support it publicly.

## GitHub setup

1. Create an empty repository with the suggested name.
2. Do not initialize it with a README, license, or `.gitignore` because those files are already included here.
3. Extract this project archive.
4. In a terminal inside the extracted folder, run:

   ```bash
   git init
   git add .
   git commit -m "Initial release: Mattermost migration wizard"
   git branch -M main
   git remote add origin https://github.com/YOUR-USERNAME/offlineops-mattermost-migration-wizard.git
   git push -u origin main
   ```

5. Replace `YOUR-USERNAME` with your GitHub username and verify the CI workflow passes.
6. Edit `README.md` and replace the `OWNER/REPO` placeholders in the CI badge URL with your actual GitHub owner/repository.
7. Review `LICENSE` ownership/copyright wording before publishing.
8. Remove `REPO_SETUP.md` from the public repo if you do not want internal publishing notes visible.

## Before making a release

- Test on a disposable staging instance.
- Review all safety claims and supported versions.
- Update `CHANGELOG.md`.
- Tag a version only when the release contents have been reviewed.
