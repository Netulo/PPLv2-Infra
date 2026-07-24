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
EXISTING_SECRET=""
EXISTING_DB_PASS=""

# ==============================================================================
# FUNKCJE POMOCNICZE
# ==============================================================================
msg_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
msg_info()   { echo -e "${CYAN} -> $1${NC}"; }
msg_succ()   { echo -e "${GREEN} [OK] $1${NC}"; }
msg_warn()   { echo -e "${YELLOW} [!] $1${NC}"; }
msg_err()    { echo -e "${RED} [ERR] $1${NC}"; }

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
        msg_warn "Wykryto istniejący plik $ENV_FILE."
        echo "1) Przerwij konfigurację"
        echo "2) Nadpisz (bez kopii zapasowej)"
        echo -e "3) Nadpisz ${YELLOW}(utwórz kopię zapasową) [DOMYŚLNE]${NC}"
        read -p "Wybierz [1/2/3]: " env_choice
        env_choice=${env_choice:-3}

        if [ "$env_choice" == "1" ]; then
            msg_info "Przerwano. Nie wprowadzono zmian."
            exit 0
        elif [ "$env_choice" == "3" ]; then
            BACKUP_ENV="${ENV_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
            cp "$ENV_FILE" "$BACKUP_ENV"
            msg_succ "Kopia zapasowa: $BACKUP_ENV"
        fi

        EXISTING_SECRET=$(grep '^SECRET_KEY=' "$ENV_FILE" | sed 's/^SECRET_KEY=//')
        EXISTING_DB_PASS=$(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | sed 's/^POSTGRES_PASSWORD=//')
        rm "$ENV_FILE"
    fi

    echo "# Wygenerowano: $(date)" > "$ENV_FILE"

    read -p "Włączyć tryb DEBUG? (tylko środowiska deweloperskie) [t/N]: " debug_choice
    debug_choice=${debug_choice:-N}
    if [[ "$debug_choice" =~ ^[TtYy]$ ]]; then
        echo "DEBUG=True" >> "$ENV_FILE"
        msg_warn "DEBUG=True (aktywny)."
    else
        echo "DEBUG=False" >> "$ENV_FILE"
        msg_info "DEBUG=False."
    fi
    
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
    
    echo "SECRET_KEY=$SECRET_KEY" >> "$ENV_FILE"
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
        msg_succ "Certyfikaty są gotowe, pomijam."
    fi
}

module_network() {
    msg_header "Konfiguracja hosta i domeny"
    echo "1) Środowisko lokalne / offline (localhost + IP LAN)"
    echo "2) Serwer docelowy (domena publiczna)"
    read -p "Wybierz typ środowiska [1/2]: " ENV_TYPE < /dev/tty

    NGINX_SERVER_NAME=""

    if [ "$ENV_TYPE" == "2" ]; then
        read -p "Podaj domenę (np. system.domena.pl): " DOMAIN_NAME < /dev/tty
        echo "ALLOWED_HOSTS=$DOMAIN_NAME" >> "$ENV_FILE"
        echo "CSRF_TRUSTED_ORIGINS=https://$DOMAIN_NAME" >> "$ENV_FILE"
        NGINX_SERVER_NAME="$DOMAIN_NAME"
    else
        read -p "Podaj lokalny adres IP z Wi-Fi (np. 192.168.1.15) [ENTER = pomiń]: " LOCAL_IP < /dev/tty
        
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
        
        echo "ALLOWED_HOSTS=$HOSTS" >> "$ENV_FILE"
        echo "CSRF_TRUSTED_ORIGINS=$TRUSTED" >> "$ENV_FILE"
        msg_info "Przypisano mDNS: $MDNS_NAME"
    fi

    msg_info "Aktualizacja konfiguracji Nginx..."
    sed "s/PLACEHOLDER_DOMAIN/$NGINX_SERVER_NAME/g" nginx/nginx.conf.template > nginx/default.conf
    msg_succ "Konfiguracja sieciowa zakończona."
}

module_smtp() {
    msg_header "Konfiguracja SMTP"
    msg_info "Dane poczty są wymagane do 2FA i resetowania haseł."
    
    read -p "Serwer SMTP (np. smtp.gmail.com): " EMAIL_HOST
    read -p "Port SMTP (465 SSL, 587 TLS): " EMAIL_PORT
    read -p "Użytkownik (e-mail): " EMAIL_USER
    read -p "Hasło SMTP: " EMAIL_PASS
    read -p "Nadawca (np. System <system@domena.pl>): " EMAIL_FROM

    echo "" >> "$ENV_FILE"
    echo "# --- EMAIL ---" >> "$ENV_FILE"
    echo "EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend" >> "$ENV_FILE"
    echo "EMAIL_HOST=$EMAIL_HOST" >> "$ENV_FILE"
    echo "EMAIL_PORT=$EMAIL_PORT" >> "$ENV_FILE"
    echo "EMAIL_HOST_USER=$EMAIL_USER" >> "$ENV_FILE"
    echo "EMAIL_HOST_PASSWORD=$EMAIL_PASS" >> "$ENV_FILE"
    echo "DEFAULT_FROM_EMAIL=$EMAIL_FROM" >> "$ENV_FILE"

    if [ "$EMAIL_PORT" == "465" ]; then
        echo "EMAIL_USE_SSL=True" >> "$ENV_FILE"
        echo "EMAIL_USE_TLS=False" >> "$ENV_FILE"
    else
        echo "EMAIL_USE_SSL=False" >> "$ENV_FILE"
        echo "EMAIL_USE_TLS=True" >> "$ENV_FILE"
    fi
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

    echo "" >> "$ENV_FILE"
    echo "# --- BAZA DANYCH ---" >> "$ENV_FILE"
    echo "USE_POSTGRES=True" >> "$ENV_FILE"
    echo "POSTGRES_DB=$DB_NAME" >> "$ENV_FILE"
    echo "POSTGRES_USER=$DB_USER" >> "$ENV_FILE"

    if [ "$DB_CHOICE" == "2" ]; then
        read -p "Adres zewnętrznej bazy (Host): " EXT_DB_HOST
        read -p "Hasło zewnętrznej bazy: " EXT_DB_PASS
        echo "DB_HOST=$EXT_DB_HOST" >> "$ENV_FILE"
        echo "POSTGRES_PASSWORD=$EXT_DB_PASS" >> "$ENV_FILE"
        
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
        echo "DB_HOST=db" >> "$ENV_FILE"
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
        echo "POSTGRES_PASSWORD=$DB_PASS" >> "$ENV_FILE"
        rm -f docker-compose.override.yml
        msg_succ "Baza lokalna skonfigurowana."
    fi

    echo "" >> "$ENV_FILE"
    echo "# --- REDIS ---" >> "$ENV_FILE"
    echo "REDIS_URL=redis://redis:6379/1" >> "$ENV_FILE"
}

module_backups() {
    msg_header "Kopie zapasowe (Backups)"
    
    # 1. Katalog Lokalny
    read -p "Lokalny katalog backupów [ENTER = ./backups]: " LOCAL_BACKUP_DIR
    if [ -n "$LOCAL_BACKUP_DIR" ]; then
        echo "BACKUP_DIR=$LOCAL_BACKUP_DIR" >> "$ENV_FILE"
        msg_info "Zapisywanie w: $LOCAL_BACKUP_DIR"
    else
        msg_info "Zapisywanie domyślne w: ./backups"
    fi

    # 2. Google Cloud Storage
    read -p "Skonfigurować eksport do Google Cloud Storage? [t/N]: " cloud_choice
    if [[ "$cloud_choice" =~ ^[TtYy]$ ]]; then
        read -p "Nazwa bucketu: " GS_BUCKET
        read -p "ID Projektu GCP: " GS_PROJECT
        read -p "Ścieżka do pliku klucza JSON: " GS_CREDENTIALS

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

        echo "" >> "$ENV_FILE"
        echo "# --- BACKUP CHMUROWY ---" >> "$ENV_FILE"
        echo "GS_BUCKET_NAME=$GS_BUCKET" >> "$ENV_FILE"
        echo "GS_PROJECT_ID=$GS_PROJECT" >> "$ENV_FILE"
        echo "GOOGLE_APPLICATION_CREDENTIALS=$GS_CREDENTIALS" >> "$ENV_FILE"
    fi

    # 3. CRON
    read -p "Dodać systemowy harmonogram zadań cron dla backupów? [T/n]: " cron_choice
    cron_choice=${cron_choice:-T}
    if [[ "$cron_choice" =~ ^[TtYy]$ ]]; then
        read -p "Godzina uruchomienia (0-23) [ENTER = 3]: " cron_hour
        cron_hour=${cron_hour:-3}
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

    echo "" >> "$ENV_FILE"
    echo "# --- RODO ---" >> "$ENV_FILE"
    echo "RODO_RETENTION_DAYS=$RETENTION_DAYS" >> "$ENV_FILE"
    msg_succ "Okres retencji: $RETENTION_DAYS dni."

    if [ "$RETENTION_DAYS" -gt 0 ]; then
        CRON_RODO="0 4 * * * cd $(pwd) && docker compose exec -T web python manage.py rodo_cleanup > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "rodo_cleanup"; echo "$CRON_RODO") | crontab -
        msg_succ "Automatyczne zadanie RODO dodane do crontab (4:00 rano)."
    fi
}

module_updates() {
    msg_header "Automatyczne aktualizacje obrazów (Watchtower)"
    read -p "Włączyć auto-aktualizacje obrazów z GHCR? [T/n]: " ENABLE_UPDATES < /dev/tty

    sed -i '/COMPOSE_PROFILES/d' "$ENV_FILE"
    sed -i '/WATCHTOWER_POLL_INTERVAL/d' "$ENV_FILE"

    if [[ "$ENABLE_UPDATES" =~ ^[Nn]$ ]]; then
        echo "COMPOSE_PROFILES=" >> "$ENV_FILE"
        msg_info "Auto-aktualizacje wyłączone."
    else
        echo "COMPOSE_PROFILES=auto-update" >> "$ENV_FILE"
        
        echo -e "\nInterwał pobierania aktualizacji:"
        echo "1) 5 minut (polecane w szczycie operacyjnym)"
        echo "2) 1 godzina (standard)"
        echo "3) 24 godziny"
        read -p "Wybierz [1/2/3] (Domyślnie 2): " INTERVAL_CHOICE < /dev/tty
        
        case "$INTERVAL_CHOICE" in
            1)
                echo "WATCHTOWER_POLL_INTERVAL=300" >> "$ENV_FILE"
                msg_succ "Interwał: 300s (5m)"
                ;;
            3)
                echo "WATCHTOWER_POLL_INTERVAL=86400" >> "$ENV_FILE"
                msg_succ "Interwał: 86400s (24h)"
                ;;
            *)
                echo "WATCHTOWER_POLL_INTERVAL=3600" >> "$ENV_FILE"
                msg_succ "Interwał: 3600s (1h)"
                ;;
        esac
    fi
}

module_versioning() {
    msg_header "Kanał obrazu aplikacji"
    echo "1) STABLE (stabilny tag)"
    echo "2) BETA (tag z najnowszym commit z main)"
    read -p "Wybierz kanał [1/2] (Domyślnie 1): " VERSION_CHOICE < /dev/tty

    sed -i '/APP_VERSION/d' "$ENV_FILE"

    if [ "$VERSION_CHOICE" == "2" ]; then
        echo "APP_VERSION=beta" >> "$ENV_FILE"
        msg_succ "Ustawiono kanał: BETA"
    else
        echo "APP_VERSION=stable" >> "$ENV_FILE"
        msg_succ "Ustawiono kanał: STABLE"
    fi
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
    docker compose pull
    
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
# GŁÓWNY BLOK WYKONAWCZY
# ==============================================================================

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