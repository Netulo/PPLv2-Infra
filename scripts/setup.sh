#!/bin/bash

# ==============================================================================
# USTAWIENIA I ZMIENNE GLOBALNE
# ==============================================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

ENV_FILE=".env"

# ==============================================================================
# FUNKCJE POMOCNICZE
# ==============================================================================
msg_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
msg_info()   { echo -e "${CYAN} -> $1${NC}"; }
msg_succ()   { echo -e "${GREEN} [OK] $1${NC}"; }
msg_warn()   { echo -e "${YELLOW} [!] $1${NC}"; }
msg_err()    { echo -e "${RED} [ERR] $1${NC}"; }

# Odczytuje obecną wartość klucza z .env (pusty string, jeśli brak pliku/klucza)
get_env_var() {
    [ -f "$ENV_FILE" ] && grep "^$1=" "$ENV_FILE" | tail -n1 | cut -d'=' -f2-
}

# Ustawia klucz w .env - edytuje istniejący wpis w miejscu (zachowując pozycję/sekcję)
# albo dopisuje nowy na końcu. Bezpieczne do wielokrotnego wywołania.
set_env_var() {
    local key="$1"
    local value="$2"
    touch "$ENV_FILE"
    if grep -q "^${key}=" "$ENV_FILE"; then
        awk -v k="$key" -v v="$value" -F'=' '$1==k{print k"="v; next}{print}' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# Usuwa klucz z .env, jeśli istnieje
unset_env_var() {
    [ -f "$ENV_FILE" ] && sed -i "/^$1=/d" "$ENV_FILE"
}

# Dopisuje nagłówek sekcji, tylko jeśli jeszcze go nie ma (unika duplikatów przy wielokrotnym uruchamianiu modułu)
ensure_section() {
    local header="$1"
    if ! grep -qxF "$header" "$ENV_FILE" 2>/dev/null; then
        echo "" >> "$ENV_FILE"
        echo "$header" >> "$ENV_FILE"
    fi
}

# ==============================================================================
# MODUŁY INSTALACYJNE
# ==============================================================================

module_init() {
    echo -e "${CYAN}"
    echo "=========================================="
    echo "     KONFIGURACJA ŚRODOWISKA PPLv2        "
    echo "=========================================="
    echo -e "${NC}"

    if [ -f "$ENV_FILE" ]; then
        BACKUP_ENV="${ENV_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
        cp "$ENV_FILE" "$BACKUP_ENV"
        msg_info "Wykryto istniejący plik $ENV_FILE. Kopia zapasowa: $BACKUP_ENV"
    else
        echo "# Wygenerowano: $(date)" > "$ENV_FILE"
    fi

    CURRENT_DEBUG=$(get_env_var DEBUG)
    read -p "Włączyć tryb DEBUG? (tylko środowiska deweloperskie)${CURRENT_DEBUG:+ [obecnie: $CURRENT_DEBUG]} [t/N]: " debug_choice
    if [ -z "$debug_choice" ] && [ -n "$CURRENT_DEBUG" ]; then
        set_env_var DEBUG "$CURRENT_DEBUG"
    elif [[ "$debug_choice" =~ ^[TtYy]$ ]]; then
        set_env_var DEBUG True
        msg_warn "DEBUG=True (aktywny)."
    else
        set_env_var DEBUG False
        msg_info "DEBUG=False."
    fi

    EXISTING_SECRET=$(get_env_var SECRET_KEY)
    if [ -n "$EXISTING_SECRET" ]; then
        msg_info "Wykryto stary klucz SECRET_KEY."
        read -p "Zachować obecny klucz? (pozwala utrzymać aktywne sesje) [T/n]: " keep_secret
        keep_secret=${keep_secret:-T}
        if [[ "$keep_secret" =~ ^[TtYy]$ ]]; then
            SECRET_KEY=$EXISTING_SECRET
            msg_succ "Przywrócono poprzedni klucz."
        else
            SECRET_KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)
            msg_succ "Wygenerowano nowy klucz."
        fi
    else
        SECRET_KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)
        msg_succ "Wygenerowano nowy klucz."
    fi
    set_env_var SECRET_KEY "$SECRET_KEY"
}

module_ssl() {
    msg_header "Certyfikaty SSL"
    mkdir -p nginx/certs
    if [ ! -f nginx/certs/server.crt ]; then
        msg_info "Generowanie certyfikatów self-signed..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout nginx/certs/server.key \
          -out nginx/certs/server.crt \
          -subj "/C=PL/ST=PPL/L=Trasa/O=PPL_Server/CN=localhost" 2>/dev/null
        msg_succ "Certyfikaty zapisane w nginx/certs/."
    else
        msg_succ "Certyfikaty są gotowe, pomijam. (Usuń nginx/certs/server.crt, aby wygenerować nowe.)"
    fi
}

module_network() {
    msg_header "Konfiguracja hosta i domeny"
    CURRENT_HOSTS=$(get_env_var ALLOWED_HOSTS)
    [ -n "$CURRENT_HOSTS" ] && msg_info "Obecne ALLOWED_HOSTS: $CURRENT_HOSTS"

    echo "1) Środowisko lokalne / offline (localhost + IP LAN)"
    echo "2) Serwer docelowy (domena publiczna)"
    read -p "Wybierz typ środowiska [1/2]: " ENV_TYPE < /dev/tty

    NGINX_SERVER_NAME=""

    if [ "$ENV_TYPE" == "2" ]; then
        read -p "Podaj domenę (np. system.domena.pl)${CURRENT_HOSTS:+ [obecnie: $CURRENT_HOSTS]}: " DOMAIN_NAME < /dev/tty
        DOMAIN_NAME=${DOMAIN_NAME:-$CURRENT_HOSTS}
        set_env_var ALLOWED_HOSTS "$DOMAIN_NAME"
        set_env_var CSRF_TRUSTED_ORIGINS "https://$DOMAIN_NAME"
        NGINX_SERVER_NAME="$DOMAIN_NAME"
    else
        CURRENT_LOCAL_IP=$(echo "$CURRENT_HOSTS" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        read -p "Podaj lokalny adres IP z Wi-Fi (np. 192.168.1.15)${CURRENT_LOCAL_IP:+ [obecnie: $CURRENT_LOCAL_IP]} [ENTER = pomiń]: " LOCAL_IP < /dev/tty
        LOCAL_IP=${LOCAL_IP:-$CURRENT_LOCAL_IP}

        MACHINE_HOSTNAME=$(hostname)
        MDNS_NAME="${MACHINE_HOSTNAME}.local"

        HOSTS="localhost,127.0.0.1,$MDNS_NAME"
        TRUSTED="https://localhost,https://127.0.0.1,http://localhost,http://127.0.0.1,https://$MDNS_NAME,http://$MDNS_NAME"
        NGINX_SERVER_NAME="localhost 127.0.0.1 $MDNS_NAME"

        if [ -n "$LOCAL_IP" ]; then
            HOSTS="$HOSTS,$LOCAL_IP"
            TRUSTED="$TRUSTED,https://$LOCAL_IP,http://$LOCAL_IP"
            NGINX_SERVER_NAME="$NGINX_SERVER_NAME $LOCAL_IP"
        fi

        set_env_var ALLOWED_HOSTS "$HOSTS"
        set_env_var CSRF_TRUSTED_ORIGINS "$TRUSTED"
        msg_info "Przypisano mDNS: $MDNS_NAME"
    fi

    msg_info "Aktualizacja konfiguracji Nginx..."
    sed "s/PLACEHOLDER_DOMAIN/$NGINX_SERVER_NAME/g" nginx/nginx.conf.template > nginx/default.conf
    msg_succ "Konfiguracja sieciowa zakończona."
}

module_smtp() {
    msg_header "Konfiguracja SMTP"
    msg_info "Dane poczty są wymagane do 2FA i resetowania haseł."

    CURRENT_HOST=$(get_env_var EMAIL_HOST)
    CURRENT_PORT=$(get_env_var EMAIL_PORT)
    CURRENT_USER=$(get_env_var EMAIL_HOST_USER)
    CURRENT_PASS=$(get_env_var EMAIL_HOST_PASSWORD)
    CURRENT_FROM=$(get_env_var DEFAULT_FROM_EMAIL)

    read -p "Serwer SMTP (np. smtp.gmail.com)${CURRENT_HOST:+ [obecnie: $CURRENT_HOST]}: " EMAIL_HOST
    EMAIL_HOST=${EMAIL_HOST:-$CURRENT_HOST}

    read -p "Port SMTP (465 SSL, 587 TLS)${CURRENT_PORT:+ [obecnie: $CURRENT_PORT]}: " EMAIL_PORT
    EMAIL_PORT=${EMAIL_PORT:-$CURRENT_PORT}

    read -p "Użytkownik (e-mail)${CURRENT_USER:+ [obecnie: $CURRENT_USER]}: " EMAIL_USER
    EMAIL_USER=${EMAIL_USER:-$CURRENT_USER}

    if [ -n "$CURRENT_PASS" ]; then
        read -p "Hasło SMTP jest już ustawione [ENTER = zachowaj, lub podaj nowe]: " EMAIL_PASS
        EMAIL_PASS=${EMAIL_PASS:-$CURRENT_PASS}
    else
        read -p "Hasło SMTP: " EMAIL_PASS
    fi

    read -p "Nadawca (np. System <system@domena.pl>)${CURRENT_FROM:+ [obecnie: $CURRENT_FROM]}: " EMAIL_FROM
    EMAIL_FROM=${EMAIL_FROM:-$CURRENT_FROM}

    ensure_section "# --- EMAIL ---"
    set_env_var EMAIL_BACKEND "django.core.mail.backends.smtp.EmailBackend"
    set_env_var EMAIL_HOST "$EMAIL_HOST"
    set_env_var EMAIL_PORT "$EMAIL_PORT"
    set_env_var EMAIL_HOST_USER "$EMAIL_USER"
    set_env_var EMAIL_HOST_PASSWORD "$EMAIL_PASS"
    set_env_var DEFAULT_FROM_EMAIL "$EMAIL_FROM"

    if [ "$EMAIL_PORT" == "465" ]; then
        set_env_var EMAIL_USE_SSL True
        set_env_var EMAIL_USE_TLS False
    else
        set_env_var EMAIL_USE_SSL False
        set_env_var EMAIL_USE_TLS True
    fi
    msg_succ "Konfiguracja SMTP zapisana."
}

module_database() {
    msg_header "Konfiguracja bazy danych (PostgreSQL)"
    echo "Wybierz typ bazy danych:"
    echo "1) Kontener lokalny (domyślne)"
    echo "2) Baza zewnętrzna (zdalny serwer IP/domena)"
    read -p "Wybór [1/2]: " DB_CHOICE
    DB_CHOICE=${DB_CHOICE:-1}

    DB_NAME="pplv2_db"
    DB_USER="pplv2_user"
    DEFAULT_DB_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

    ensure_section "# --- BAZA DANYCH ---"
    set_env_var USE_POSTGRES True
    set_env_var POSTGRES_DB "$DB_NAME"
    set_env_var POSTGRES_USER "$DB_USER"

    if [ "$DB_CHOICE" == "2" ]; then
        CURRENT_EXT_HOST=$(get_env_var DB_HOST)
        read -p "Adres zewnętrznej bazy (Host)${CURRENT_EXT_HOST:+ [obecnie: $CURRENT_EXT_HOST]}: " EXT_DB_HOST
        EXT_DB_HOST=${EXT_DB_HOST:-$CURRENT_EXT_HOST}

        CURRENT_EXT_PASS=$(get_env_var POSTGRES_PASSWORD)
        if [ -n "$CURRENT_EXT_PASS" ]; then
            read -p "Hasło zewnętrznej bazy jest już ustawione [ENTER = zachowaj, lub podaj nowe]: " EXT_DB_PASS
            EXT_DB_PASS=${EXT_DB_PASS:-$CURRENT_EXT_PASS}
        else
            read -p "Hasło zewnętrznej bazy: " EXT_DB_PASS
        fi

        set_env_var DB_HOST "$EXT_DB_HOST"
        set_env_var POSTGRES_PASSWORD "$EXT_DB_PASS"

        cat <<EOF > docker-compose.override.yml
services:
  db:
    profiles:
      - disabled
  web:
    depends_on:
      - redis
EOF
        msg_succ "Konfiguracja zewnętrzna zapisana. Wyłączono lokalny kontener DB."
    else
        set_env_var DB_HOST db
        EXISTING_DB_PASS=$(get_env_var POSTGRES_PASSWORD)
        if [ -n "$EXISTING_DB_PASS" ]; then
            msg_info "Wykryto istniejące hasło bazy danych."
            read -p "Zachować obecne hasło? [T/n]: " keep_db_pass
            keep_db_pass=${keep_db_pass:-T}
            if [[ "$keep_db_pass" =~ ^[TtYy]$ ]]; then
                DB_PASS=$EXISTING_DB_PASS
                msg_succ "Przywrócono poprzednie hasło."
            else
                DB_PASS=${DEFAULT_DB_PASS}
                msg_succ "Wygenerowano nowe hasło bazy."
            fi
        else
            DB_PASS=${DEFAULT_DB_PASS}
        fi
        set_env_var POSTGRES_PASSWORD "$DB_PASS"
        rm -f docker-compose.override.yml
        msg_succ "Baza lokalna skonfigurowana."
    fi

    ensure_section "# --- REDIS ---"
    set_env_var REDIS_URL "redis://redis:6379/1"
}

module_backups() {
    msg_header "Kopie zapasowe (Backups)"

    # 1. Katalog Lokalny
    CURRENT_BACKUP_DIR=$(get_env_var BACKUP_DIR)
    read -p "Lokalny katalog backupów${CURRENT_BACKUP_DIR:+ [obecnie: $CURRENT_BACKUP_DIR]} [ENTER = ./backups]: " LOCAL_BACKUP_DIR
    LOCAL_BACKUP_DIR=${LOCAL_BACKUP_DIR:-$CURRENT_BACKUP_DIR}
    if [ -n "$LOCAL_BACKUP_DIR" ]; then
        set_env_var BACKUP_DIR "$LOCAL_BACKUP_DIR"
        msg_info "Zapisywanie w: $LOCAL_BACKUP_DIR"
    else
        msg_info "Zapisywanie domyślne w: ./backups"
    fi

    # 2. Google Cloud Storage
    CURRENT_GS_BUCKET=$(get_env_var GS_BUCKET_NAME)
    if [ -n "$CURRENT_GS_BUCKET" ]; then
        read -p "Eksport do GCS jest skonfigurowany (bucket: $CURRENT_GS_BUCKET). Zachować/edytować? [T/n]: " cloud_choice
        cloud_choice=${cloud_choice:-T}
    else
        read -p "Skonfigurować eksport do Google Cloud Storage? [t/N]: " cloud_choice
        cloud_choice=${cloud_choice:-N}
    fi

    if [[ "$cloud_choice" =~ ^[TtYy]$ ]]; then
        CURRENT_GS_PROJECT=$(get_env_var GS_PROJECT_ID)
        CURRENT_GS_CREDENTIALS=$(get_env_var GOOGLE_APPLICATION_CREDENTIALS)

        read -p "Nazwa bucketu${CURRENT_GS_BUCKET:+ [obecnie: $CURRENT_GS_BUCKET]}: " GS_BUCKET
        GS_BUCKET=${GS_BUCKET:-$CURRENT_GS_BUCKET}
        read -p "ID Projektu GCP${CURRENT_GS_PROJECT:+ [obecnie: $CURRENT_GS_PROJECT]}: " GS_PROJECT
        GS_PROJECT=${GS_PROJECT:-$CURRENT_GS_PROJECT}
        read -p "Ścieżka do pliku klucza JSON${CURRENT_GS_CREDENTIALS:+ [obecnie: $CURRENT_GS_CREDENTIALS]}: " GS_CREDENTIALS
        GS_CREDENTIALS=${GS_CREDENTIALS:-$CURRENT_GS_CREDENTIALS}

        msg_info "Weryfikacja dostępu do GCP..."

        cat <<EOF > test_gcs.py
import sys
try:
    from google.cloud import storage
    from google.oauth2 import service_account
    credentials = service_account.Credentials.from_service_account_file('$GS_CREDENTIALS')
    client = storage.Client(project='$GS_PROJECT', credentials=credentials)
    bucket = client.bucket('$GS_BUCKET')
    if not bucket.exists():
        sys.exit(1)
except Exception as e:
    sys.exit(1)
EOF

        if [ -f ".venv/bin/python" ]; then
            .venv/bin/python test_gcs.py > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                msg_succ "Połączono z Google Cloud Storage."
            else
                msg_err "Błąd autoryzacji GCP. Konfiguracja dodana do pliku .env do weryfikacji."
            fi
        else
            msg_warn "Brak .venv, pominięto test GCS. Dodano wpisy do .env."
        fi

        rm -f test_gcs.py

        ensure_section "# --- BACKUP CHMUROWY ---"
        set_env_var GS_BUCKET_NAME "$GS_BUCKET"
        set_env_var GS_PROJECT_ID "$GS_PROJECT"
        set_env_var GOOGLE_APPLICATION_CREDENTIALS "$GS_CREDENTIALS"
    else
        unset_env_var GS_BUCKET_NAME
        unset_env_var GS_PROJECT_ID
        unset_env_var GOOGLE_APPLICATION_CREDENTIALS
        [ -n "$CURRENT_GS_BUCKET" ] && msg_info "Usunięto konfigurację GCS."
    fi

    # 3. CRON
    read -p "Dodać/zaktualizować systemowy harmonogram zadań cron dla backupów? [T/n]: " cron_choice
    cron_choice=${cron_choice:-T}
    if [[ "$cron_choice" =~ ^[TtYy]$ ]]; then
        CURRENT_CRON_HOUR=$(crontab -l 2>/dev/null | grep "run_smart_backup" | awk '{print $2}')
        read -p "Godzina uruchomienia (0-23) [ENTER = ${CURRENT_CRON_HOUR:-3}]: " cron_hour
        cron_hour=${cron_hour:-${CURRENT_CRON_HOUR:-3}}
        read -p "Częstotliwość w dniach [ENTER = 1]: " cron_days
        cron_days=${cron_days:-1}

        if [ "$cron_days" == "1" ]; then
            cron_day_expr="*"
        else
            cron_day_expr="*/$cron_days"
        fi

        CRON_CMD="0 $cron_hour $cron_day_expr * * cd $(pwd) && docker compose exec -T web python manage.py run_smart_backup > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "run_smart_backup"; echo "$CRON_CMD") | crontab -
        msg_succ "Zadanie backupów dodane do crontab."

        let "clean_hour = $cron_hour"
        CRON_CLEAN_CMD="5 $clean_hour * * * cd $(pwd) && docker compose exec -T web python manage.py clearsessions > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "clearsessions"; echo "$CRON_CLEAN_CMD") | crontab -
        msg_succ "Zadanie czyszczenia sesji dodane do crontab."
    fi
}

module_rodo() {
    msg_header "Retencja danych (RODO)"
    CURRENT_RETENTION=$(get_env_var RODO_RETENTION_DAYS)
    [ -n "$CURRENT_RETENTION" ] && msg_info "Obecna wartość: $CURRENT_RETENTION dni"

    echo "Okres przechowywania danych nieaktywnych uczestników:"
    echo "0) Brak automatycznego usuwania"
    echo "1) 1 rok (365 dni)"
    echo "2) 3 lata (1095 dni - standard)"
    echo "3) 5 lat (1825 dni)"
    echo "4) Niestandardowy czas (w latach)"
    read -p "Wybierz [0/1/2/3/4] (Domyślnie 2): " rodo_choice
    rodo_choice=${rodo_choice:-2}

    case $rodo_choice in
        1) RETENTION_DAYS=365 ;;
        2) RETENTION_DAYS=1095 ;;
        3) RETENTION_DAYS=1825 ;;
        4)
            read -p "Ilość lat: " custom_years
            if ! [[ "$custom_years" =~ ^[0-9]+$ ]]; then
                msg_warn "Błędna wartość. Ustawiono 3 lata."
                RETENTION_DAYS=1095
            else
                RETENTION_DAYS=$((custom_years * 365))
            fi
            ;;
        *) RETENTION_DAYS=0 ;;
    esac

    ensure_section "# --- RODO ---"
    set_env_var RODO_RETENTION_DAYS "$RETENTION_DAYS"
    msg_succ "Okres retencji: $RETENTION_DAYS dni."

    if [ "$RETENTION_DAYS" -gt 0 ]; then
        CRON_RODO="0 4 * * * cd $(pwd) && docker compose exec -T web python manage.py rodo_cleanup > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "rodo_cleanup"; echo "$CRON_RODO") | crontab -
        msg_succ "Automatyczne zadanie RODO dodane do crontab (4:00 rano)."
    else
        (crontab -l 2>/dev/null | grep -v "rodo_cleanup") | crontab -
    fi
}

module_updates() {
    msg_header "Automatyczne aktualizacje obrazów (Watchtower)"

    CURRENT_PROFILE=$(get_env_var COMPOSE_PROFILES)
    if [ "$CURRENT_PROFILE" == "auto-update" ]; then
        msg_info "Auto-aktualizacje są obecnie WŁĄCZONE (interwał: $(get_env_var WATCHTOWER_POLL_INTERVAL)s)."
    else
        msg_info "Auto-aktualizacje są obecnie WYŁĄCZONE."
    fi
    read -p "Włączyć auto-aktualizacje obrazów z GHCR? [T/n]: " ENABLE_UPDATES < /dev/tty

    unset_env_var COMPOSE_PROFILES
    unset_env_var WATCHTOWER_POLL_INTERVAL

    # Usuwamy ewentualny stary wpis @reboot, żeby moduł był bezpieczny do ponownego uruchomienia
    (crontab -l 2>/dev/null | grep -v "PPLv2 boot-update") | crontab -

    if [[ "$ENABLE_UPDATES" =~ ^[Nn]$ ]]; then
        set_env_var COMPOSE_PROFILES ""
        msg_info "Auto-aktualizacje wyłączone."
    else
        set_env_var COMPOSE_PROFILES "auto-update"

        echo -e "\nInterwał pobierania aktualizacji:"
        echo "1) 5 minut (polecane w szczycie operacyjnym)"
        echo "2) 1 godzina (standard)"
        echo "3) 24 godziny"
        read -p "Wybierz [1/2/3] (Domyślnie 2): " INTERVAL_CHOICE < /dev/tty

        case "$INTERVAL_CHOICE" in
            1)
                set_env_var WATCHTOWER_POLL_INTERVAL 300
                msg_succ "Interwał: 300s (5m)"
                ;;
            3)
                set_env_var WATCHTOWER_POLL_INTERVAL 86400
                msg_succ "Interwał: 86400s (24h)"
                ;;
            *)
                set_env_var WATCHTOWER_POLL_INTERVAL 3600
                msg_succ "Interwał: 3600s (1h)"
                ;;
        esac

        msg_info "Rejestrowanie zadania cron uruchamianego przy restarcie serwera..."
        CRON_BOOT_CMD="@reboot bash -c 'until docker info >/dev/null 2>&1; do sleep 2; done; cd $(pwd) && docker compose pull && docker compose up -d' >> /var/log/pplv2_boot_update.log 2>&1 # PPLv2 boot-update"
        (crontab -l 2>/dev/null | grep -v "PPLv2 boot-update"; echo "$CRON_BOOT_CMD") | crontab -
        msg_succ "Po restarcie serwera obrazy będą automatycznie pobierane i uruchamiane (log: /var/log/pplv2_boot_update.log)."
    fi
}

module_versioning() {
    msg_header "Kanał obrazu aplikacji"
    CURRENT_VERSION=$(get_env_var APP_VERSION)
    [ -n "$CURRENT_VERSION" ] && msg_info "Obecny kanał: $CURRENT_VERSION"

    echo "1) STABLE (stabilny tag)"
    echo "2) BETA (tag z najnowszym commit z main)"
    read -p "Wybierz kanał [1/2] (Domyślnie 1): " VERSION_CHOICE < /dev/tty

    if [ "$VERSION_CHOICE" == "2" ]; then
        set_env_var APP_VERSION beta
        msg_succ "Ustawiono kanał: BETA"
    else
        set_env_var APP_VERSION stable
        msg_succ "Ustawiono kanał: STABLE"
    fi
}

# Lekka wersja "docker_start" dla pojedynczych zmian z menu - migracje i collectstatic
# wykonuje teraz automatycznie entrypoint.sh obrazu web przy każdym starcie kontenera.
module_apply() {
    local do_pull="$1"
    msg_header "Zastosowanie zmian"
    read -p "Przeładować kontenery teraz (docker compose up -d)? [T/n]: " apply_choice
    apply_choice=${apply_choice:-T}

    if [[ ! "$apply_choice" =~ ^[TtYy]$ ]]; then
        msg_info "Pominięto. Uruchom ręcznie: docker compose up -d"
        return
    fi

    if [ "$do_pull" == "--pull" ]; then
        msg_info "Pobieranie obrazów..."
        if ! docker compose pull; then
            msg_err "Pobieranie obrazów nie powiodło się - przerwano (kontenery NIE zostały zrestartowane)."
            msg_warn "Sprawdź: czy 'docker login ghcr.io' jest wykonane dla użytkownika, który to uruchamia (uwaga: root i zwykły użytkownik mają OSOBNE dane logowania), oraz czy token ma uprawnienie 'read:packages'."
            return 1
        fi
    fi

    msg_info "Restart kontenerów..."
    docker compose up -d
    msg_succ "Gotowe. Migracje i pliki statyczne zostaną zastosowane automatycznie przy starcie kontenera web."
}

module_docker_start() {
    msg_header "Uruchomienie kontenerów"
    read -p "Pobrać obrazy i uruchomić Docker Compose teraz? [T/n]: " RUN_DOCKER
    RUN_DOCKER=${RUN_DOCKER:-T}

    if [[ ! "$RUN_DOCKER" =~ ^[TtYy]$ ]]; then
        msg_info "Konfiguracja zakończona. Uruchom polecenie ręcznie: docker compose up -d"
        return
    fi

    msg_info "Pobieranie najnowszych obrazów z rejestru..."
    if ! docker compose pull; then
        msg_err "Pobieranie obrazów nie powiodło się - przerwano."
        msg_warn "Sprawdź: czy 'docker login ghcr.io' jest wykonane dla użytkownika, który to uruchamia (uwaga: root i zwykły użytkownik mają OSOBNE dane logowania), oraz czy token ma uprawnienie 'read:packages'."
        return 1
    fi

    msg_info "Uruchamianie kontenerów..."
    docker compose up -d

    msg_info "Oczekiwanie na inicjalizację bazy..."
    sleep 5

    msg_info "Wykonywanie migracji schematu bazy danych..."
    docker compose exec -T web python manage.py migrate

    msg_info "Zbieranie plików statycznych..."
    docker compose exec -T web python manage.py collectstatic --noinput

    msg_header "Konfiguracja zakończona."
    msg_warn "Zalecane: Utwórz konto administratora wywołując:"
    echo -e "${YELLOW}docker compose exec -it web python manage.py createsuperuser${NC}"
}

# ==============================================================================
# PEŁNY KREATOR (pierwsza instalacja)
# ==============================================================================

run_full_setup() {
    module_init
    module_ssl
    module_versioning
    module_network
    module_smtp
    module_database
    module_backups
    module_rodo
    module_updates
    module_docker_start
}

# ==============================================================================
# MENU (ponowne uruchomienie na już skonfigurowanym serwerze)
# ==============================================================================

show_menu() {
    msg_header "Menu konfiguracji PPLv2"
    echo " 1) Pełna (re)konfiguracja od zera"
    echo " 2) Certyfikaty SSL"
    echo " 3) Kanał wersji obrazu (stable/beta)"
    echo " 4) Sieć / domena / Nginx"
    echo " 5) SMTP (e-mail)"
    echo " 6) Baza danych"
    echo " 7) Kopie zapasowe (Backups)"
    echo " 8) Retencja danych (RODO)"
    echo " 9) Automatyczne aktualizacje (Watchtower)"
    echo "10) Zastosuj zmiany / restart kontenerów"
    echo " 0) Wyjście"
    read -p "Wybierz opcję: " menu_choice < /dev/tty

    case "$menu_choice" in
        1) run_full_setup ;;
        2) module_ssl; module_apply ;;
        3) module_versioning; module_apply --pull ;;
        4) module_network; module_apply ;;
        5) module_smtp; module_apply ;;
        6) module_database; module_apply ;;
        7) module_backups; module_apply ;;
        8) module_rodo; module_apply ;;
        9) module_updates; module_apply --pull ;;
        10) module_apply --pull ;;
        0) msg_info "Zakończono bez zmian."; exit 0 ;;
        *) msg_err "Nieznana opcja."; exit 1 ;;
    esac
}

# ==============================================================================
# GŁÓWNY BLOK WYKONAWCZY
# ==============================================================================

if [ -f "$ENV_FILE" ]; then
    while true; do
        show_menu
    done
else
    run_full_setup
fi
