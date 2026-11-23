# Lampion

A native macOS control panel for local web development: start, stop and monitor Apache, PHP and MariaDB,
with a built-in database manager. Written in SwiftUI, runs natively on Apple Silicon.

## Features

- **Overview:** server cards for Apache, MariaDB and PHP with state, port, PID and version; start, stop and restart;
  shortcuts to the site, phpMyAdmin, the database manager, the web folder and Terminal; recent activity.
- **Configuration:** settings pages for Apache (port, web folder, .htaccess, directory listing, modules, log level),
  PHP (limits, error display and logging, time zone, OPcache, sessions) and MariaDB (port, network access, capacity,
  character set and collation, SQL mode, slow and general query logs). Every change is checked by the server itself
  before it is written, only the changed lines are touched, the original file is kept as `<name>.lampion-backup`,
  and the server restarts to apply it. MariaDB settings live in their own file, `my.cnf.d/lampion.cnf`.
- **Logs:** Lampion's activity plus Apache errors and requests, PHP errors, the MariaDB log and its query logs,
  followed live, split into time, tag and message, filterable by level and searchable.
- **General:** open at login, start servers when Lampion opens, stop them when it quits, automatic update checks.
- **One folder:** sites, databases, logs and backups live in `~/Lampion` (`www/`, `databases/`, `logs/`, `backups/`),
  like XAMPP keeps everything together. New installs start there; existing ones move with General › Locations › Move….
  Homebrew always starts MariaDB with `--datadir=/opt/homebrew/var/mysql`, so that path becomes a link to
  `~/Lampion/databases`. The old copies are kept (`/opt/homebrew/var/mysql.lampion-old`).
- **Connecting from apps:** like XAMPP, `root` has no password, from this Mac only (TCP and socket). MariaDB settings
  show the host, port and socket and copy ready-made settings for PHP, Laravel, Prisma, Node.js, Python and Java.
  phpMyAdmin signs in automatically. Both can be turned off.
- **Database manager:** database and table tree, editable data grid (filter, sort, paging), export to and
  import from SQL files.
- **Table structure:** table designer, add, change and reorder columns, indexes and primary keys, foreign keys,
  rename, move and copy tables, change engine and collation, optimize / repair / analyze / check.
- **SQL editor:** syntax highlighting, suggestions while you type, error marking after a failed query.
- **Updates:** the app checks GitHub for a newer release and updates itself with one click.
- Every command is also available from the menu bar.

## Requirements

- macOS 14 or later, Apple Silicon
- [Homebrew](https://brew.sh) — if it is missing, the app offers to install it

Apache, PHP, MariaDB and phpMyAdmin are downloaded and configured automatically the first time you open the app.
It runs `brew install httpd php mariadb phpmyadmin`, enables PHP and phpMyAdmin in Apache's `httpd.conf` (the
original is kept as `httpd.conf.lampion-backup`), adds a welcome page to the web folder and starts the servers.
A banner at the top of the window shows the progress. If you already have Apache installed and only the PHP
configuration is missing, the app asks before changing it.

## Install

Download `Lampion-<version>.dmg` from the [latest release](https://github.com/Kokai555/lampion/releases/latest),
open it and drag **Lampion** onto **Applications**.

The app is not notarized by Apple, so macOS blocks it the first time you open it. To allow it, try to open the app once,
then go to **System Settings → Privacy & Security** and click **Open Anyway**.

On first launch the app downloads the server software by itself; this can take several minutes.

## Build from source

Building needs Xcode.

```sh
./build.sh
```

This builds the app and installs it to `/Applications/Lampion.app`.

To create the disk image, run `./package.sh`; it writes `build/Lampion-<version>.dmg`.

## Project layout

```
Sources/
├── App/                 app entry point, menu bar commands, updater, snapshot tool
├── Core/                Homebrew paths, process runner, small helpers
├── Config/              reading and writing httpd.conf, php.ini and lampion.cnf
│   └── Views/           the Apache, PHP, MariaDB and General settings pages
├── Logs/                log sources, live file follower, the Logs pane
├── Servers/             server control: state, start/stop/restart logic, self-test
│   └── Views/           main window: sidebar, overview cards, shared components
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
open -a Lampion --args --selftest   # server start/stop (restarts the servers while it runs)
open -a Lampion --args --dbtest     # database manager, on a temporary test database
```

Results are written to `~/Library/Logs/Lampion.log` and `~/Library/Logs/Lampion-dbtest.log`.

To check the design, `build/Lampion.app/Contents/MacOS/Lampion --snapshot <folder>` saves a PNG of every pane
(and every log) and quits. Run it from Terminal so it can use Terminal's screen recording permission; without it,
the images are drawn without the translucent sidebar.
