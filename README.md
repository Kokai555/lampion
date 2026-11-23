# Szerverpanel

A native macOS control panel for local web development: start, stop and monitor Apache, PHP and MariaDB,
with a built-in database manager. Written in SwiftUI, runs natively on Apple Silicon.

## Features

- **Servers:** start and stop Apache and MariaDB, see PIDs and ports, detect port conflicts,
  open config files and logs, event log.
- **Database manager:** database and table tree, editable data grid (filter, sort, paging),
  table structure, SQL editor with Tab completion, export to and import from SQL files.
- Every command is also available from the menu bar.

## Requirements

- macOS 14 or later, Apple Silicon
- Xcode (to build)
- Homebrew under `/opt/homebrew` with these packages:

```sh
brew install httpd php mariadb phpmyadmin
```

PHP and phpMyAdmin have to be wired into Apache's `httpd.conf` (see the output of `brew info php` and
`brew info phpmyadmin`).

## Build and install

```sh
./build.sh
```

This builds the app and installs it to `/Applications/Szerverpanel.app`.

## Self-tests

```sh
open -a Szerverpanel --args --selftest   # server start/stop (restarts the servers while it runs)
open -a Szerverpanel --args --dbtest     # database manager, on a temporary test database
```

Results are written to `~/Library/Logs/Szerverpanel.log` and `~/Library/Logs/Szerverpanel-dbtest.log`.
