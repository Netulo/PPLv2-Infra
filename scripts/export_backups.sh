#!/bin/bash
# Kopiuje 3 najnowsze lokalne backupy bazy danych na dysk zewnętrzny/pendrive.
# Czyta bezpośrednio z ./backups na hoście (bind-mount z docker-compose.yml,
# patrz komentarz przy usłudze `web`) zamiast przez `docker compose exec`,
# żeby uniknąć potrzeby osobnego bind-mounta dla konkretnej ścieżki
# pendrive'a - ta ścieżka jest inna na każdej maszynie i nie da się jej
# zaszyć na stałe w docker-compose.yml.
set -e
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

msg_succ() { echo -e "${GREEN} [OK] $1${NC}"; }
msg_warn() { echo -e "${YELLOW} [!] $1${NC}"; }
msg_err()  { echo -e "${RED} [ERR] $1${NC}"; }

DEST="$1"
if [ -z "$DEST" ]; then
    msg_err "Użycie: $0 <ścieżka-docelowa> (np. /media/usb lub D:\\ pod WSL)"
    exit 1
fi

if [ ! -d "./backups" ] || [ -z "$(ls -A ./backups 2>/dev/null)" ]; then
    msg_warn "Katalog ./backups jest pusty lub nie istnieje - nie ma czego kopiować."
    exit 0
fi

if [ ! -d "$DEST" ]; then
    msg_err "Ścieżka '$DEST' nie istnieje. Czy nośnik jest podpięty?"
    exit 1
fi

TARGET_DIR="$DEST/PPLv2_Bazy_Kopie"
mkdir -p "$TARGET_DIR"

# 3 najnowsze pliki wg daty modyfikacji. Process substitution (nie mapfile)
# celowo - działa też na starszym bash (np. domyślny bash 3.2 na macOS).
copied=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    cp -p "./backups/$f" "$TARGET_DIR/$f"
    msg_succ "Skopiowano: $f"
    copied=$((copied + 1))
done < <(ls -t ./backups | head -n 3)

if [ "$copied" -eq 0 ]; then
    msg_warn "Brak plików backupu w ./backups."
    exit 0
fi

msg_succ "Gotowe. Skopiowano $copied plik(ów) do: $TARGET_DIR"
