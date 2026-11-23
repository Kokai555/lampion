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
- [Homebrew](https://brew.sh) — if it is missing, the app offers to install it

Apache, PHP, MariaDB and phpMyAdmin are installed and configured for you on first launch: the app shows a
**Set Up** banner when something is missing. Set Up runs `brew install httpd php mariadb phpmyadmin`, enables PHP
and phpMyAdmin in Apache's `httpd.conf` (the original is kept as `httpd.conf.szerverpanel-backup`) and adds a
welcome page to the web folder.

## Install

Download `Szerverpanel-<version>.dmg` from the [latest release](https://github.com/Kokai555/szerverpanel/releases/latest),
open it and drag **Szerverpanel** onto **Applications**.

The app is not notarized by Apple, so macOS blocks it the first time you open it. To allow it, try to open the app once,
then go to **System Settings → Privacy & Security** and click **Open Anyway**.

On first launch, click **Set Up** in the banner at the top of the window to download the server software.

## Build from source

Building needs Xcode.

```sh
./build.sh
```

This builds the app and installs it to `/Applications/Szerverpanel.app`.

To create the disk image, run `./package.sh`; it writes `build/Szerverpanel-<version>.dmg`.

## Project layout

```
Sources/
├── App/                 app entry point and menu bar commands
├── Core/                Homebrew paths, process runner, small helpers
├── Servers/             server control: state, start/stop logic, self-test
│   └── Views/           main window: module table, status badge, event log
└── Database/
    ├── Engine/          talks to MariaDB through the `mariadb` client, parses results
    ├── Model/           database manager state, completion data, self-test
    ├── Editor/          SQL editor: syntax highlighting, suggestions, error marking
    └── Views/           database window: sidebar, data grid, structure, query, sheets
Tools/                   app icon generator
build.sh                 build and install
package.sh               build the disk image
```

## Self-tests

```sh
open -a Szerverpanel --args --selftest   # server start/stop (restarts the servers while it runs)
open -a Szerverpanel --args --dbtest     # database manager, on a temporary test database
```

Results are written to `~/Library/Logs/Szerverpanel.log` and `~/Library/Logs/Szerverpanel-dbtest.log`.
