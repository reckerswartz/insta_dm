# Browser sessions

Post-Phase-3, every `InstagramAccount` gets its own persistent Chromium
profile on disk, managed by
`Instagram::Browser::AccountContext`. Cookies, localStorage, IndexedDB,
service workers, and Playwright-tracked auth state all live in the
profile dir and survive process restarts without a DB round-trip.

## Layout

```
storage/
└── browser_sessions/
    ├── 1/        # InstagramAccount id = 1
    ├── 42/       # InstagramAccount id = 42
    └── .keep     # optional; created lazily
```

The root is configurable:

```bash
PLAYWRIGHT_BROWSER_SESSIONS_ROOT=/data/ig/browser_sessions bin/dev
```

## Lifecycle

- `Instagram::Browser::PlaywrightRuntime` owns the singleton Node driver
  for the Ruby process. One Node subprocess per Ruby process, shared
  across all accounts and threads.
- `Instagram::Browser::AccountContext.new(account:).with_context do |ctx|`
  launches `chromium.launch_persistent_context(user_data_dir: ...)`.
  A class-level `Mutex` keyed by `account.id` guarantees at-most-one
  Chromium per account within the process.
- Across processes (e.g. multiple Sidekiq workers), Chromium's own
  profile-lock file rejects concurrent opens of the same `user_data_dir`.
  A second process trying to open the same account will see a
  `Playwright::Error("browser is already running")` and the job will
  retry per the facade's `SessionRecoverySupport`.

## First-time login

```ruby
InstagramAccount.first.client.manual_login!(timeout_seconds: 300)
```

Opens a non-headless Chromium window on the per-account profile dir,
navigates to `/accounts/login/`, and polls `context.cookies` for a
`sessionid` cookie. 2FA flows through the browser just like a human
user would. Once `sessionid` lands:

1. `Instagram::Browser::SessionExporter#export!` copies the
   `storage_state` into the encrypted DB columns
   (`cookies_json`, `local_storage_json`, `auth_snapshot_json`,
   `user_agent`) as a portable backup.
2. `account.login_state = "authenticated"` is persisted.
3. The Chromium context closes; subsequent `with_authenticated_driver`
   calls open the same profile dir with the session already live.

## Backup + restore

`Instagram::Browser::SessionExporter` translates between Playwright's
`storage_state` shape and the legacy encrypted DB columns. Two flows:

**Export (after a session run):**
```ruby
Instagram::Browser::AccountContext.new(account: acct).with_context do |ctx|
  Instagram::Browser::SessionExporter.new(account: acct).export!(ctx)
end
```

**Import (bootstrap a new host from DB):**
```ruby
exporter = Instagram::Browser::SessionExporter.new(account: acct)
exporter.import!(path: "storage/browser_sessions/#{acct.id}/state.json")
# Playwright picks up state.json from the persistent-context dir on the
# next launch, so no manual_login! is needed.
```

This gives you a portable backup in the encrypted DB row. Moving an
account between hosts is `import!` → run anything that calls
`with_authenticated_driver` → new profile dir populated.

## Troubleshooting

| Symptom                                                   | Fix                                                                                 |
|-----------------------------------------------------------|-------------------------------------------------------------------------------------|
| `AuthenticationRequiredError: No stored cookies and no persistent browser profile` | Run `client.manual_login!` once.                                                    |
| `Playwright::Error: browser is already running`            | Another process holds the profile lock. Check `ps -ef | grep chromium | grep <id>`; `kill` the stale process, or wait for the other worker to finish. |
| Chromium binary missing after `yarn install`              | Run `NODE_OPTIONS="--use-system-ca" npx playwright install chromium`.               |
| Session works but acts logged-out                         | Nuke the profile dir: `rm -rf storage/browser_sessions/<account_id>` and `manual_login!` again. DB backup columns stay intact; `SessionExporter#import!` can seed the new dir. |
| `Playwright::TimeoutError` everywhere                     | Headless mode might be rendering differently than Instagram expects. Try `INSTAGRAM_HEADLESS=false` for a visual debug. |
| TLS errors talking to Instagram                           | Set `INSTAGRAM_CHROME_IGNORE_CERT_ERRORS=true` for local debugging behind a corporate proxy.|

## Lifecycle hooks

- `AccountContext#with_page` attaches
  `Instagram::Browser::PageInstrumentation` to every yielded page, so
  console + network events are captured and surfaced by
  `TaskCaptureSupport` in `log/instagram_debug/<date>/*.json`.
- `AccountContext#wipe!` removes the on-disk profile dir; the DB
  backup columns are untouched. Useful when Instagram issues a
  challenge that breaks the existing storage state.

## Headful vs headless

Default is headful (`INSTAGRAM_HEADLESS=false`). Automated jobs set
`INSTAGRAM_HEADLESS=true` via the worker env. For visual debugging:

```bash
INSTAGRAM_HEADLESS=false bin/rails runner \
  'InstagramAccount.first.client.with_authenticated_driver { |d| sleep 60 }'
```
