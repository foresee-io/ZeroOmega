# Git Remote Sync for ZeroOmega

## Motivation

ZeroOmega originally supported cloud sync only via GitHub Gist. While Gist works
well for individual users on GitHub, it has limitations:

- **Vendor lock-in**: Users must have a GitHub account and use GitHub's Gist API.
- **No self-hosting**: Organizations or privacy-conscious users cannot use
  internal Git servers.
- **No branch control**: Gist uses a single revision history with no branching.

Git Remote Sync extends ZeroOmega to synchronize options with **any** Git
repository accessible over HTTPS — including GitHub, GitLab, Gitea, Bitbucket,
and self-hosted Git servers.

## Architecture

### Transport Abstraction

The sync system has three layers:

```
OptionsSync (omega-target)        — Backend-agnostic orchestrator
  ├── merge, debounce, push sequencing, pull scheduling
  └── delegates transport to Storage
ChromeSyncStorage (chromium-ext)  — Storage + sync lifecycle
  ├── IndexedDB store, watch, onChangedListener
  ├── processPush / processPull / processCheckCommit
  └── delegates remote calls to Backend
Backend (transport layer)         — Remote API implementation
  ├── GistBackend   — GitHub Gist API (fetch + PATCH)
  └── GitHttpBackend — Git smart HTTP protocol (isomorphic-git)
```

**Key design principle**: The outer logic (conflict resolution, debounce, push
sequencing, polling, error state management) is shared between both backends.
Only the transport operations differ.

### Backend Interface

Both backends implement the same interface:

| Method | Returns | Description |
|--------|---------|-------------|
| `init({withRemoteData})` | `{options?, lastGistCommit}` | Clone/fetch remote; optionally read remote data |
| `push(data)` | `{lastGistCommit}` | Upload merged options |
| `pull()` | `{options, lastGistCommit}` | Fetch and read remote options |
| `checkChange()` | `string \| undefined` | Get remote HEAD commit hash |

The `lastGistCommit` field name is reused for both backends to avoid changing
the state machine or storage keys.

### URL-Based Backend Selection

`ChromeSyncStorage.init()` inspects the `gistId` field:

- If it starts with `https://gist.github.com/` → `GistBackend`
- Otherwise → `GitHttpBackend` (treats the value as a Git remote URL)

This preserves full backward compatibility: existing Gist users are unaffected.

## Technical Approach: GitHttpBackend

### isomorphic-git

[isomorphic-git](https://isomorphic-git.org/) is a pure JavaScript
reimplementation of Git that works in browsers and Node.js. It uses standard
`fetch` for HTTP requests, which works in MV3 service workers thanks to the
`<all_urls>` host permission.

### Bundle Integration

isomorphic-git's CJS source uses modern JS (async/await) that the project's
Browserify v3 cannot parse. We work around this by:

1. Pointing the `browser` field in `package.json` to the pre-built UMD bundles:
   - `isomorphic-git` → `index.umd.min.js`
   - `isomorphic-git/http/web` → `http/web/index.umd.js`
2. Adding these files to Browserify's `noParse` list so it includes them
   without parsing their internals.

Bundle size impact: ~300 KB (uncompressed) added to the extension.

### In-Memory Filesystem

isomorphic-git requires an `fs` implementation. Since the repo contains only one
file (`ZeroOmega.json`), we use a minimal in-memory filesystem backed by a
plain JS object. No IndexedDB or persistent filesystem is needed — the repo is
re-cloned or re-fetched on each sync cycle.

Supported operations: `readFile`, `writeFile`, `mkdir`, `readdir`, `stat`,
`lstat`, `unlink`, `rmdir`.

### Git Operations

| Operation | isomorphic-git API | Notes |
|-----------|-------------------|-------|
| Initial clone | `git.clone({depth:1, singleBranch:true})` | Shallow, one branch |
| Check for changes | `git.listServerRefs({prefix})` | Only fetches ref advertisement |
| Pull | `git.fetch({depth:1, singleBranch:true})` | Updates working tree |
| Push | `git.add` + `git.commit` + `git.push({force:true})` | Force push allowed |
| Read file | `fs.readFile` from in-memory FS | Handles missing file gracefully |

### Authentication

Git HTTP authentication uses `onAuth` callback with HTTP Basic Auth:

```javascript
onAuth: () => ({ username: syncUsername, password: gistToken })
```

- `syncUsername` — Git username (for servers requiring Basic Auth)
- `gistToken` — Password or personal access token

For GitHub specifically, use a PAT with `repo` scope as the password and `git`
(or any string) as the username.

### Async Console Logging

Every major Git operation logs its step and parameters to the browser developer
console, matching the existing Gist error logging pattern:

```
GitHttpBackend: clone start https://example.com/repo.git branch: main
GitHttpBackend: clone complete
GitHttpBackend: HEAD abc123...
GitHttpBackend: push start
GitHttpBackend: add
GitHttpBackend: commit
GitHttpBackend: push commit def456...
GitHttpBackend: push done
```

### Error Exposure

HTTP errors from Git operations are caught, formatted with the status code, and
exposed to the frontend via the same `lastGistState` field used by Gist sync:

```
fail: HTTP 401 ... (authentication required)
fail: HTTP 404 ... (repository not found)
```

### File Existence Handling

GitHttpBackend does **not** assume `ZeroOmega.json` exists in the remote repo:

- If the file is missing → `pull()` returns `{options: undefined}`
- If the file contains invalid JSON → `pull()` returns `{options: undefined}`

This is safe because empty/undefined options produce no changes through
`operationsForChanges` — local data is never wiped by a missing or malformed
remote file.

## Configuration

### Field Mapping

| Purpose | Storage Key | Gist Value | Git Remote Value |
|---------|-------------|-----------|-----------------|
| Remote URL / ID | `gistId` | Gist URL or ID | Full HTTPS repo URL |
| Auth token | `gistToken` | GitHub PAT | Password or PAT |
| Branch | `syncBranch` | *(not used)* | Branch name (required) |
| Username | `syncUsername` | *(not used)* | Git username |
| Last commit | `lastGistCommit` | Gist commit SHA | Git commit SHA |
| Sync state | `lastGistState` | `success` / `fail: ...` | Same |
| Last sync time | `lastGistSync` | Timestamp | Same |

### UI Behavior

The sync form adapts based on the URL input:

- **Gist URL** (starts with `https://gist.github.com/`): Shows "Gist Id" label,
  Gist-specific help text and links. Hides Branch and Username fields.
- **Other URL**: Shows "Repo URL" label, shows Branch (required) and Username
  fields, shows generic HTTPS auth help text.

## Conflict Handling

### How It Works

Both backends reuse the same conflict resolution in `OptionsSync`:

1. `checkChange()` compares the remote commit hash with `lastGistCommit`.
2. If different, `pull()` fetches remote options.
3. `processPull()` computes a changes diff against local state.
4. `onChangedListener` applies the diff via `operationsForChanges`.
5. For local changes, `processPush()` batches writes with a 600ms debounce
   and pushes the full merged state.

### Known Limitations

The current conflict mechanism has architectural limitations:

1. **No optimistic concurrency control**: `_doPush` reads the merge base from
   local sync storage, not from the remote server. If two devices push
   simultaneously, the second push overwrites the first (Gist PATCH is an
   overwrite; Git force push is also an overwrite).

2. **Race window**: Between `checkChange`/`pull` and `push`, remote changes
   can arrive unnoticed.

3. **Revision comparison is local only**: `Revision.compare` decides which of
   two local versions is newer but does not prevent overwriting a newer remote
   version.

4. **Empty object edge case**: If a remote file contains `{}` (valid JSON but
   empty object), `processPull` would compute changes that delete all local
   options. This is a pre-existing limitation also present in Gist sync.

These are documented rather than fixed. Fixing would require a CAS/ETag
mechanism at the transport level, which the Gist API does not support.

## Security

- Tokens/passwords are stored in extension local state (`chrome.storage.local`),
  never synced via Chrome Sync or exposed in the options page URL.
- Only HTTPS URLs are supported for Git remotes.
- Error messages exposed to the frontend (`lastGistState`) are sanitized —
  tokens and full URLs are not included.
- Force push is limited to the configured branch only.

## Compatibility

- **Gist users**: Fully backward compatible. The URL prefix check ensures
  GistBackend is used for all existing configurations.
- **Migration**: Users can switch from Gist to Git Remote by changing the URL
  field. No data migration is needed — the new backend will clone fresh.
- **Browser support**: isomorphic-git uses `fetch`, `ArrayBuffer`,
  `crypto.subtle`, and `TextEncoder`/`TextDecoder` — all available in MV3
  service workers with the `<all_urls>` host permission.

## Service Worker Considerations

MV3 service workers can be terminated by the browser at any time. Long-running
Git operations (especially initial clone of large repos) may be interrupted.

Mitigations:
- Shallow clone (`depth: 1`) minimizes data transfer.
- Single-branch clone reduces ref negotiation.
- On next alarm cycle (every 5 minutes), `checkChange()` will detect the
  failure and retry.
- All operations are idempotent — a partial push that was committed locally
  but not uploaded will be retried on the next sync cycle.
