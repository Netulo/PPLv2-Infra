#!/bin/bash
# Jedno miejsce do sprawdzenia, czy serwer jest aktualny: repo Infra, obraz
# aplikacji (web) i Watchtower. Uruchamiaj zamiast ręcznego odpytywania
# git/docker po kolei.
set -e
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

msg_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
msg_info()   { echo -e "${CYAN} -> $1${NC}"; }
msg_succ()   { echo -e "${GREEN} [OK] $1${NC}"; }
msg_warn()   { echo -e "${YELLOW} [!] $1${NC}"; }
msg_err()    { echo -e "${RED} [ERR] $1${NC}"; }

msg_header "Repo PPLv2-Infra"
if git rev-parse --git-dir > /dev/null 2>&1; then
    if git fetch origin --quiet 2>/tmp/status_fetch_err; then
        LOCAL=$(git rev-parse HEAD)
        REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "$LOCAL")
        if [ "$LOCAL" == "$REMOTE" ]; then
            msg_succ "Aktualne (${LOCAL:0:7})"
        else
            msg_warn "W TYLE za origin/main! lokalnie: ${LOCAL:0:7}, na GitHub: ${REMOTE:0:7}"
            msg_info "Uruchom: git merge --ff-only origin/main"
        fi
    else
        msg_err "git fetch nie powiódł się:"
        cat /tmp/status_fetch_err
    fi
else
    msg_warn "To nie jest checkout git - nie da się porównać z GitHub."
fi

msg_header "Obraz aplikacji (web)"
if docker compose exec -T web python manage.py buildinfo 2>/tmp/status_web_err; then
    :
else
    msg_err "Nie udało się odpytać kontenera web:"
    cat /tmp/status_web_err
fi

msg_header "Watchtower"
if docker ps --filter "name=pplv2_watchtower" --filter "status=running" -q | grep -q .; then
    msg_succ "Działa."
    RECENT_ERRORS=$(docker logs pplv2_watchtower --since 24h 2>&1 | grep -i "level=error" || true)
    if [ -n "$RECENT_ERRORS" ]; then
        msg_warn "Błędy w logach z ostatnich 24h:"
        echo "$RECENT_ERRORS" | tail -5
    else
        msg_succ "Brak błędów w logach z ostatnich 24h."
    fi
else
    msg_err "Kontener NIE działa (sprawdź COMPOSE_PROFILES=auto-update w .env i uruchom: docker compose up -d watchtower)"
fi

rm -f /tmp/status_fetch_err /tmp/status_web_err
