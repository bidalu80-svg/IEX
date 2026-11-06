# GitHub connector authorization and repository operations

## Verified references

- GitHub OAuth scopes: https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps
  `repo` authorizes public/private repository operations within the user's own privileges; `workflow` is separate. Requested scopes are not evidence of granted access. GitHub App authorization does not use OAuth scopes.
- Authenticated repository listing: https://docs.github.com/en/rest/repos/repos#list-repositories-for-the-authenticated-user
  The connector requests `affiliation=owner,collaborator,organization_member` and returns `has_more`/`next_page` from the response Link header. Agents are instructed to continue pages. This avoids the previous silent first-100 repository limit.
- Reference update: https://docs.github.com/en/rest/git/refs#update-a-reference
  Atomic multi-file operations create blobs, a tree and one commit, then PATCH the branch with `force:false`. A fresh expected head is mandatory and checked before object creation and again immediately before pushing. GitHub rejects a concurrent non-fast-forward update. Protected branches/rules and organization policy remain enforced by GitHub.
- OAuth device client reference: https://github.com/cli/cli/blob/eeb44bc432c0107de002dadd34a61b4e2bd15882/internal/authflow/flow.go
  Build-time `GitHubOAuthClientID` remains preferred. Without it, the public GitHub CLI OAuth client `178c6fc778ccc68e1d6a` is used, replacing the prior Copilot GitHub App client whose permission model did not accept requested `repo` scopes. Device flow sends no client secret. The login screen explicitly says the authorization page identifies **GitHub CLI**. This app identity is not presented as a Ze-owned OAuth registration. A Ze-owned OAuth app can be supplied by build configuration.
- Official mark: https://github.com/primer/octicons/blob/b3e95564299217e1bcc6cd07d62e57d74fb9bc09/icons/mark-github-16.svg
  The original SVG is stored in `Assets.xcassets/GitHubMark.imageset/mark-github.svg`; the MIT license is preserved in `docs/third-party/octicons-LICENSE.txt`. Template rendering uses the current foreground color in light/dark modes. The previous SF Symbol cat is removed.

## Actual behavior

The settings entry and page title are `GitHub连接器`. Multiple accounts retain Keychain token storage. Reauthorizing an existing login preserves the account UUID and refreshes profile and scope metadata. Token response scope is supplemented by the authoritative `X-OAuth-Scopes` response header. A missing scope header is shown as permissions determined by the token's repository authorization; it is not represented as unrestricted access. Existing records decode without new metadata.

Device login requests `repo read:org workflow read:user user:email`. Scope is necessary but does not override repository roles, fine-grained token selection, organization approval/SSO, archive state or branch rules. Account rows display this distinction and offer reauthorization. 403 permission/SSO failures are distinct from actual rate limits; 401, 404, 409 and other API errors retain useful meaning.

The model has the existing account/list/read/single-file write/delete tools plus:

- `github_repository_info`: actual repository permissions, default branch and selected branch head SHA. An empty/missing branch yields `branch_error`, not a fabricated head.
- `github_commit_push`: JSON array of text additions/updates/deletions committed together. Content includes original whitespace and empty strings. Existing executable modes are preserved unless explicitly changed. Affected tree directories are read without trusting truncated results. The target branch is advanced without force; a changed head fails without a ref write. Loose Git objects may remain when a race or error prevents publication.
- `github_branch_create`: creates a new remote branch from an explicitly supplied full commit SHA; an existing ref is not overwritten.

Writes continue through the app's existing confirmation gate, showing account, repository, branch, commit message and affected paths. Real API errors determine final success; token material is never returned in tool results. Single-file operations retain Contents API SHA conflict checks. The existing file read tool is UTF-8 text oriented and explicitly truncates large responses at 30,000 characters; this change does not claim arbitrary binary cloning or local git checkout. Empty repositories require an initial single-file Contents API commit before Git tree-based commits can read a head.

## Verification

- Windows local: `python scripts/verify-github-connector.py` passed **23 structural checks**; changed-file `git diff --check` passed.
- macOS runtime command: `bash scripts/test-github-client.sh`. This compiles the **production** transport/model/repository client with URLProtocol fixtures, not a reimplementation.
- Runtime fixture coverage: multiple repository pages and affiliations; 403 SSO/permission vs rate limits; 429/401/409; one multi-file commit with exact whitespace, empty file, deletion and preserved executable mode; explicit non-force push; concurrent branch advancement causes no PATCH; read-only permission causes no Git writes; new branch creation; scope parsing and URL encoding.
- At handoff, runtime fixtures have been added but have **not run on this Windows host**. Full iOS compile, real OAuth login, organization SSO and real remote mutation remain separately verified by CI/device testing. No live account credentials or remote repositories were mutated by the fixture suite.

## Rollback

Revert the connector implementation commit to restore prior behavior. Account metadata adds an optional field and preserves existing UUIDs/Keychain service, so old account entries remain readable. Revoking an OAuth grant or deleting an account is an explicit user action; code rollback does not silently revoke accounts or tokens.


## Final review corrections

- All single-file read/write/delete endpoints use the same validated Contents path builder before any confirmation or HTTP request. Dot segments, empty segments, absolute paths, backslashes and control characters are rejected. Owner/repository segments also reject dot names and separators; valid hyphen, underscore and dotted repository names remain accepted. The multi-file client reuses file-path validation.
- Inline file reading explicitly requires `encoding:base64`, a declared size no larger than **1 MiB**, exact decoded-size equality and valid UTF-8. `encoding:none` responses and missing/partial content produce an explicit error; they never become successful empty files. A genuine zero-byte base64 file succeeds. Output beyond 30,000 characters is marked with both a notice and `truncated:true`. No `download_url` is followed.
- Account metadata writes now throw instead of logging-and-success. Metadata is atomically written before Keychain changes; a metadata failure leaves credentials unchanged. If an atomic Keychain change fails, the old metadata is restored and the error reaches the login UI. Published account state changes only after both operations succeed. Deletion uses the same ordering and shows a persistent-error alert. If restoring old metadata also fails, the error explicitly requests reauthorization rather than claiming success. Disk and Keychain are separate storage systems; this is synchronous failure recovery, not a cross-storage crash-atomic transaction.
- `scripts/test-github-client.sh` additionally compiles the **entire production gateway** with account and denied-confirmation fixtures. It verifies invalid paths fail before confirmation/network, while valid dotted/hyphenated names and empty write content reach confirmation. Client fixtures exercise encoding:none, size mismatch, the 1 MiB bound, actual empty files, and account persistence ordering/rollback. These newly added cases require the next macOS CI run; Windows structural checks and diff checks alone do not establish their runtime results.
- The two-head-check plus `force:false` protocol rejects ordinary concurrent branch advancement, but is not a server-side expected-SHA compare-and-swap. A concurrent forced rollback to an ancestor between the final GET and PATCH can still permit a fast-forward update. No stronger atomic-CAS claim is made.
