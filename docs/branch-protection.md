# Branch protection on `main`

Applied with the GitHub REST API (`PUT /repos/li-brandon/runway/branches/main/protection`) for LIB-454.

| Setting | Value |
|---|---|
| Required status check | `Build and test` (strict: branch must be up to date with `main`) |
| Pull request required | Yes, 0 approvals |
| Enforce for admins | No |
| Force pushes | Blocked |
| Branch deletion | Blocked |

`Build and test` is the CI gate job in `.github/workflows/ios.yml`. It always reports: it passes when the iOS build passed, or when the change is docs-only and the build was skipped.

Check the current settings with:

```sh
gh api repos/li-brandon/runway/branches/main/protection
```
