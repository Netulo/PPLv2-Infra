#!/bin/bash
# Kopiuje .env (SECRET_KEY, CRYPTOGRAPHY_KEY, PESEL_HASH_KEY, hasła) w bezpieczne
# miejsce, ODDZIELNE od backupów bazy danych. Uruchamiane ręcznie - raz zaraz po
# wygenerowaniu kluczy przez setup.sh, i ponownie po każdej zmianie .env
# (np. rotacja hasła SMTP). .env żyje na hoście (docker-compose wstrzykuje go
# do kontenerów przez env_file, ale plik sam w sobie nigdy nie jest tam
# montowany), więc to zwykły skrypt powłoki, nie polecenie manage.py.
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
    msg_err "Użycie: $0 <ścieżka-docelowa>"
    msg_err "Ścieżka musi być GDZIE INDZIEJ niż BACKUP_DIR/GS_BUCKET_NAME - menedżer haseł"
    msg_err "zsynchronizowany z dyskiem, inny pendrive niż ten używany do backupów bazy, sejf."
    exit 1
fi

if [ ! -f ".env" ]; then
    msg_err "Nie znaleziono .env w $(pwd)"
    exit 1
fi

# Zabezpieczenie przed przypadkowym umieszczeniem kopii .env w tym samym
# miejscu co backupy bazy danych - to dokładnie ten problem, któremu ten
# skrypt ma zapobiegać.
BACKUP_DIR_HOST="$(pwd)/backups"
RESOLVED_DEST="$(cd "$(dirname "$DEST")" 2>/dev/null && pwd)/$(basename "$DEST")" || RESOLVED_DEST="$DEST"
if [ "$RESOLVED_DEST" = "$BACKUP_DIR_HOST" ] || [[ "$RESOLVED_DEST" == "$BACKUP_DIR_HOST"/* ]]; then
    msg_err "'$DEST' to ten sam katalog co lokalny folder backupów bazy danych ($BACKUP_DIR_HOST)."
    msg_err "Kopia .env NIE MOŻE tam trafić - ktoś, kto ukradnie jedno miejsce, ukradłby oba:"
    msg_err "zaszyfrowane dane i klucz do ich odszyfrowania. Wskaż inną lokalizację."
    exit 1
fi

mkdir -p "$DEST"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEST_FILE="$DEST/.env.backup_$TIMESTAMP"

cp ".env" "$DEST_FILE"
chmod 600 "$DEST_FILE"

msg_succ "Skopiowano .env do: $DEST_FILE"
msg_warn "WAŻNE: ta kopia zawiera SECRET_KEY, CRYPTOGRAPHY_KEY, PESEL_HASH_KEY i hasła."
msg_warn "Nigdy nie przechowuj jej razem z backupami bazy danych (ten sam bucket GCS, ten sam"
msg_warn "pendrive/folder) - jeśli ktoś ukradnie oba naraz, odszyfruje wszystkie dane osobowe."
msg_warn "Przenieś tę kopię do menedżera haseł, sejfu albo innego nośnika, a potem usuń ją stąd."
