# Szerverpanel

Natív macOS kezelőpanel helyi webfejlesztéshez: Apache, PHP és MariaDB indítása, leállítása és felügyelete,
beépített adatbázis-kezelővel. SwiftUI-ban készült, Apple Siliconon natívan fut.

## Mit tud

- **Szerverek:** Apache és MariaDB indítása/leállítása, PID és port kijelzése, portütközés felismerése,
  beállítófájlok és naplók megnyitása, eseménynapló.
- **Adatbázis-kezelő:** adatbázis- és táblafa, szerkeszthető adatrács (szűrés, rendezés, lapozás),
  táblaszerkezet, SQL-szerkesztő Tab-kiegészítéssel, export és import SQL fájlból.
- Minden parancs elérhető a menüsorból is.

## Követelmények

- macOS 14 vagy újabb, Apple Silicon
- Xcode (a fordításhoz)
- Homebrew az `/opt/homebrew` alatt, ezekkel a csomagokkal:

```sh
brew install httpd php mariadb phpmyadmin
```

A PHP-t és a phpMyAdmint az Apache `httpd.conf` fájljában kell bekötni (lásd a `brew info php` és
`brew info phpmyadmin` kimenetét).

## Fordítás és telepítés

```sh
./build.sh
```

Ez lefordítja az appot, és az `/Applications/Szerverpanel.app` helyre telepíti.

## Önteszt

```sh
open -a Szerverpanel --args --selftest   # szerverek indítása/leállítása (közben újraindítja őket)
open -a Szerverpanel --args --dbtest     # adatbázis-kezelő, ideiglenes tesztadatbázison
```

Az eredmény a `~/Library/Logs/Szerverpanel.log` és a `~/Library/Logs/Szerverpanel-dbtest.log` fájlba kerül.
