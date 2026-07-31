#!/bin/bash
# Kopiuje folder eksportu legacy MSSQL (bck_*.csv) do kontenera `web`,
# uruchamia manage.py import_pilgrims, i usuwa kopię wewnątrz kontenera -
# `web` widzi tylko własny filesystem, więc ten krok nie może być zrobiony
# przez samo manage.py (proces w kontenerze nie ma dostępu do hosta). Kopia
# na hoście (argument tego skryptu) NIE jest usuwana automatycznie - to
# prawdziwe dane PESEL/PII, usuń ją ręcznie po sprawdzeniu wyniku migracji.
set -e
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

msg_succ() { echo -e "${GREEN} [OK] $1${NC}"; }
msg_warn() { echo -e "${YELLOW} [!] $1${NC}"; }
msg_err()  { echo -e "${RED} [ERR] $1${NC}"; }

SRC="$1"
if [ -z "$SRC" ]; then
    msg_err "Użycie: $0 <folder-z-eksportem-bck_*.csv>"
    exit 1
fi

if [ ! -d "$SRC" ]; then
    msg_err "Folder '$SRC' nie istnieje."
    exit 1
fi

FOLDER_NAME="$(basename "$SRC")"
CONTAINER_PATH="data_import/$FOLDER_NAME"

msg_warn "Kopiowanie '$SRC' do kontenera web:/app/$CONTAINER_PATH ..."
docker compose cp "$SRC" "web:/app/$CONTAINER_PATH"

# `set -e` wyłączone tylko na czas tej komendy - potrzebujemy prawdziwego
# kodu wyjścia manage.py, żeby wiedzieć, czy sprzątać kopię w kontenerze
# jako "zaimportowaną", zamiast zgadywać po treści wyjścia na stdout.
set +e
docker compose exec web python manage.py import_pilgrims "$CONTAINER_PATH"
IMPORT_EXIT=$?
set -e

msg_warn "Usuwanie kopii wewnątrz kontenera (dane nie są już tam potrzebne)..."
docker compose exec web rm -rf "$CONTAINER_PATH"

if [ "$IMPORT_EXIT" -ne 0 ]; then
    msg_err "Import zakończony błędem (kod $IMPORT_EXIT) - zobacz komunikat powyżej."
    msg_err "Kopia na hoście ('$SRC') NIE została usunięta - popraw dane i spróbuj ponownie."
    exit "$IMPORT_EXIT"
fi

msg_succ "Import zakończony pomyślnie."
msg_warn "Kopia źródłowa nadal jest na hoście: $SRC"
msg_warn "To prawdziwe dane PESEL/PII - usuń ją ręcznie (rm -rf \"$SRC\"), a jeśli eksport"
msg_warn "trafił tu z nośnika wymiennego (pendrive, dysk zewnętrzny), wyczyść też jego."
