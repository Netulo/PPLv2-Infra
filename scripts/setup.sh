#!/bin/bash

# ==============================================================================
# USTAWIENIA I ZMIENNE GLOBALNE
# ==============================================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

ENV_FILE=".env"
EXISTING_SECRET=""
EXISTING_DB_PASS=""

# ==============================================================================
# FUNKCJE POMOCNICZE (Wypisywanie ładnych logów na ekran)
# ==============================================================================
msg_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
msg_info()   { echo -e "${CYAN} -> $1${NC}"; }
msg_succ()   { echo -e "${GREEN} [OK] $1${NC}"; }
msg_warn()   { echo -e "${YELLOW} [OSTRZEŻENIE] $1${NC}"; }
msg_err()    { echo -e "${RED} [BŁĄD] $1${NC}"; }

# ==============================================================================
# MODUŁY INSTALACYJNE
# ==============================================================================

module_init() {
    echo -e "${CYAN}"
    echo "======================================================"
    echo "    KREATOR INSTALACJI SYSTEMU PPLv2 (PRO & FIELD)    "
    echo "======================================================"
    echo -e "${NC}"

    if [ -f "$ENV_FILE" ]; then
        msg_warn "Znaleziono istniejący plik $ENV_FILE!"
        echo "1) Przerwij instalację"
        echo "2) Kontynuuj i nadpisz (BEZ kopii zapasowej starych ustawień)"
        echo -e "3) Kontynuuj i nadpisz ${YELLOW}(Zrób kopię zapasową starego pliku) [DOMYŚLNE]${NC}"
        read -p "Wybór [1/2/3]: " env_choice
        env_choice=${env_choice:-3}

        if [ "$env_choice" == "1" ]; then
            msg_succ "Przerywam kreator. Nic nie zmieniono."
            exit 0
        elif [ "$env_choice" == "3" ]; then
            BACKUP_ENV="${ENV_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
            cp "$ENV_FILE" "$BACKUP_ENV"
            msg_info "Utworzono kopię zapasową starego pliku do: $BACKUP_ENV"
        fi

        EXISTING_SECRET=$(grep '^SECRET_KEY=' "$ENV_FILE" | sed 's/^SECRET_KEY=//')
        EXISTING_DB_PASS=$(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | sed 's/^POSTGRES_PASSWORD=//')
        rm "$ENV_FILE"
    fi

    echo "# Wygenerowano: $(date)" > "$ENV_FILE"

    read -p "Czy włączyć tryb DEBUG (tylko dla celów programistycznych)? [t/N]: " debug_choice
    debug_choice=${debug_choice:-N}
    if [[ "$debug_choice" =~ ^[TtYy]$ ]]; then
        echo "DEBUG=True" >> "$ENV_FILE"
        msg_warn "Włączono tryb DEBUG (Nie używaj na produkcji!)."
    else
        echo "DEBUG=False" >> "$ENV_FILE"
        msg_info "Tryb DEBUG wyłączony (Bezpieczeństwo)."
    fi
    
    if [ -n "$EXISTING_SECRET" ]; then
        msg_info "Znaleziono SECRET_KEY w starej konfiguracji."
        read -p "Czy chcesz go zachować (zalecane, by nie wylogować wszystkich)? [T/n]: " keep_secret
        keep_secret=${keep_secret:-T}
        if [[ "$keep_secret" =~ ^[TtYy]$ ]]; then
            SECRET_KEY=$EXISTING_SECRET
            msg_succ "Zachowano stary klucz zabezpieczeń."
        else
            SECRET_KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)
            msg_warn "Wygenerowano NOWY klucz zabezpieczeń."
        fi
    else
        SECRET_KEY=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)
        msg_succ "Wygenerowano nowy klucz zabezpieczeń."
    fi
    
    echo "SECRET_KEY=$SECRET_KEY" >> "$ENV_FILE"
}

module_ssl() {
    msg_header "Konfiguracja Certyfikatów SSL (HTTPS)"
    mkdir -p nginx/certs
    if [ ! -f nginx/certs/server.crt ]; then
        msg_info "Generowanie lokalnych certyfikatów SSL (Self-Signed)..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout nginx/certs/server.key \
          -out nginx/certs/server.crt \
          -subj "/C=PL/ST=PPL/L=Trasa/O=PPL_Server/CN=localhost" 2>/dev/null
        msg_succ "Certyfikaty SSL wygenerowane."
    else
        msg_succ "Certyfikaty SSL już istnieją, pomijam."
    fi
}

module_network() {
    msg_header "Zabezpieczenia Sieciowe (Host/CSRF)"
    echo "1) Lokalna / Laptop w Trasie (Dostęp przez localhost i IP z Wi-Fi)"
    echo "2) Serwer Publiczny (Dostęp przez prawdziwą domenę)"
    read -p "Wybór [1/2]: " ENV_TYPE < /dev/tty

    NGINX_SERVER_NAME=""

    if [ "$ENV_TYPE" == "2" ]; then
        read -p "Podaj domenę aplikacji (np. system.pielgrzymka.pl): " DOMAIN_NAME < /dev/tty
        echo "ALLOWED_HOSTS=$DOMAIN_NAME" >> "$ENV_FILE"
        echo "CSRF_TRUSTED_ORIGINS=https://$DOMAIN_NAME" >> "$ENV_FILE"
        NGINX_SERVER_NAME="$DOMAIN_NAME"
    else
        read -p "Podaj adres IP laptopa w sieci Wi-Fi (np. 192.168.1.15) [ENTER aby pominąć]: " LOCAL_IP < /dev/tty
        
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
        msg_info "Dodano automatyczny adres z Avahi: $MDNS_NAME"
    fi

    msg_info "Generowanie pliku konfiguracyjnego Nginx..."
    sed "s/PLACEHOLDER_DOMAIN/$NGINX_SERVER_NAME/g" nginx/nginx.conf.template > nginx/default.conf
    msg_succ "Zabezpieczenia sieciowe i Nginx skonfigurowane."
}

module_smtp() {
    msg_header "Konfiguracja E-mail (SMTP)"
    msg_warn "System używa SMTP do wysyłki tokenów, 2FA oraz resetu haseł!"
    
    read -p "Serwer SMTP (np. smtp.gmail.com): " EMAIL_HOST
    read -p "Port SMTP (465 dla SSL, 587 dla TLS): " EMAIL_PORT
    read -p "Użytkownik SMTP (adres e-mail): " EMAIL_USER
    read -p "Hasło SMTP (znaki będą widoczne): " EMAIL_PASS
    read -p "Domyślny nadawca (np. Pielgrzymka <kontakt@domena.pl>): " EMAIL_FROM

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
    msg_header "Konfiguracja Bazy Danych (PostgreSQL)"
    echo "Gdzie znajduje się baza danych dla tej instancji?"
    echo "1) Wbudowana lokalnie (Uruchomiona w kontenerze Docker)"
    echo "2) Zewnętrzny serwer (Chmura, np. używając tego samego źródła dla wielu laptopów)"
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
        read -p "Podaj adres IP lub domenę zewnętrznej bazy danych: " EXT_DB_HOST
        read -p "Podaj hasło do zewnętrznej bazy: " EXT_DB_PASS
        echo "DB_HOST=$EXT_DB_HOST" >> "$ENV_FILE"
        echo "POSTGRES_PASSWORD=$EXT_DB_PASS" >> "$ENV_FILE"
        
        # Wyłączamy lokalnego postgresa, żeby zaoszczędzić RAM na laptopie w trasie
        cat <<EOF > docker-compose.override.yml
services:
  db:
    profiles:
      - disabled
  web:
    depends_on:
      - redis
EOF
        msg_succ "Połączono z bazą zewnętrzną. Lokalny kontener DB został wyciszony."
    else
        echo "DB_HOST=db" >> "$ENV_FILE"
        if [ -n "$EXISTING_DB_PASS" ]; then
            msg_info "Znaleziono zapisane hasło do bazy danych."
            read -p "Czy chcesz je zachować? [T/n]: " keep_db_pass
            keep_db_pass=${keep_db_pass:-T}
            if [[ "$keep_db_pass" =~ ^[TtYy]$ ]]; then
                DB_PASS=$EXISTING_DB_PASS
                msg_succ "Zachowano obecne hasło bazy."
            else
                DB_PASS=${DEFAULT_DB_PASS}
                msg_warn "Ustawiono nowe hasło."
            fi
        else
            DB_PASS=${DEFAULT_DB_PASS}
        fi
        echo "POSTGRES_PASSWORD=$DB_PASS" >> "$ENV_FILE"
        # Usunięcie override, jeśli ktoś zrezygnował z bazy zewnętrznej na rzecz lokalnej
        rm -f docker-compose.override.yml
        msg_succ "Baza danych (Lokalna) skonfigurowana."
    fi

    echo "" >> "$ENV_FILE"
    echo "# --- REDIS (Cache & Rate Limiting) ---" >> "$ENV_FILE"
    echo "REDIS_URL=redis://redis:6379/1" >> "$ENV_FILE"
}

module_backups() {
    msg_header "Zarządzanie Zapasowymi Kopiami Bezpieczeństwa (Backups)"
    
    # 1. Katalog Lokalny
    read -p "Podaj lokalną ścieżkę do zapisu backupów [ENTER = domyślnie ./backups]: " LOCAL_BACKUP_DIR
    if [ -n "$LOCAL_BACKUP_DIR" ]; then
        echo "BACKUP_DIR=$LOCAL_BACKUP_DIR" >> "$ENV_FILE"
        msg_info "Backupy lokalne w: $LOCAL_BACKUP_DIR"
    else
        msg_info "Backupy lokalne będą zapisywane w domyślnym katalogu ./backups"
    fi

    # 2. Konfiguracja Chmury (Google Cloud Storage)
    read -p "Czy chcesz podpiąć replikację backupów do Google Cloud Storage? [t/N]: " cloud_choice
    if [[ "$cloud_choice" =~ ^[TtYy]$ ]]; then
        read -p "Nazwa koszyka (Bucket Name): " GS_BUCKET
        read -p "Project ID: " GS_PROJECT
        read -p "Ścieżka na hoście do pliku JSON z kluczami: " GS_CREDENTIALS

        msg_info "Weryfikacja dostępu do Google Cloud..."
        
        cat <<EOF > test_gcs.py
import sys
try:
    from google.cloud import storage
    from google.oauth2 import service_account
    credentials = service_account.Credentials.from_service_account_file('$GS_CREDENTIALS')
    client = storage.Client(project='$GS_PROJECT', credentials=credentials)
    bucket = client.bucket('$GS_BUCKET')
    if not bucket.exists():
        print('Koszyk (Bucket) nie istnieje!')
        sys.exit(1)
    print('OK')
except ImportError:
    print('Brak zainstalowanej biblioteki google-cloud w środowisku .venv.')
    sys.exit(1)
except Exception as e:
    print(f'Błąd połączenia: {e}')
    sys.exit(1)
EOF

        if [ -f ".venv/bin/python" ]; then
            .venv/bin/python test_gcs.py > .gcs_test_result 2>&1
            if [ $? -eq 0 ]; then
                msg_succ "Połączenie z Google Cloud powiodło się!"
            else
                msg_err "Błąd autoryzacji Google Cloud!"
                msg_warn "Konfiguracja dodana, ale wymaga poprawy."
            fi
        else
            msg_warn "Brak .venv, pomijam test, ale dodaję do .env."
        fi
        
        rm -f test_gcs.py .gcs_test_result

        echo "" >> "$ENV_FILE"
        echo "# --- BACKUP CHMUROWY ---" >> "$ENV_FILE"
        echo "GS_BUCKET_NAME=$GS_BUCKET" >> "$ENV_FILE"
        echo "GS_PROJECT_ID=$GS_PROJECT" >> "$ENV_FILE"
        echo "GOOGLE_APPLICATION_CREDENTIALS=$GS_CREDENTIALS" >> "$ENV_FILE"
    else
        msg_info "Kopie zapasowe wyłącznie na lokalnym dysku."
    fi

    # 3. Automatyzacja CRON na hoście
    read -p "Czy dodać automatyczny harmonogram CRON na tym serwerze? [T/n]: " cron_choice
    cron_choice=${cron_choice:-T}
    if [[ "$cron_choice" =~ ^[TtYy]$ ]]; then
        
        read -p "O której godzinie wykonywać backup? (0-23) [ENTER = 3]: " cron_hour
        cron_hour=${cron_hour:-3}
        
        read -p "Co ile dni wykonywać backup? (1-31) [ENTER = 1]: " cron_days
        cron_days=${cron_days:-1}
        
        if [ "$cron_days" == "1" ]; then
            cron_day_expr="*"
        else
            cron_day_expr="*/$cron_days"
        fi

        CRON_CMD="0 $cron_hour $cron_day_expr * * cd $(pwd) && docker compose exec -T web python manage.py run_smart_backup > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "run_smart_backup"; echo "$CRON_CMD") | crontab -
        msg_succ "Zainstalowano zadanie CRON do backupów."

        let "clean_hour = $cron_hour"
        CRON_CLEAN_CMD="5 $clean_hour * * * cd $(pwd) && docker compose exec -T web python manage.py clearsessions > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "clearsessions"; echo "$CRON_CLEAN_CMD") | crontab -
        msg_succ "Zainstalowano zadanie CRON czyszczenia sesji."
    fi
}

module_rodo() {
    msg_header "Zgodność z RODO (Retencja Danych)"
    
    echo "Polityka usuwania starych danych osobowych."
    echo "Wybierz czas przechowywania danych nieaktywnych pielgrzymów:"
    echo "0) Nigdy nie usuwaj automatycznie (Wymaga ręcznego czyszczenia bazy)"
    echo "1) 1 rok (365 dni)"
    echo "2) 3 lata (1095 dni - Standard księgowy)"
    echo "3) 5 lat (1825 dni)"
    echo "4) Inna ilość lat (wpisz ręcznie)"
    read -p "Wybór [0/1/2/3/4, domyślnie 2]: " rodo_choice
    rodo_choice=${rodo_choice:-2}

    case $rodo_choice in
        1) RETENTION_DAYS=365 ;;
        2) RETENTION_DAYS=1095 ;;
        3) RETENTION_DAYS=1825 ;;
        4) 
            read -p "Podaj ilość lat retencji (np. 7): " custom_years
            if ! [[ "$custom_years" =~ ^[0-9]+$ ]]; then
                msg_warning "Wpisano niepoprawną wartość. Ustawiam 3 lata."
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
    msg_succ "Zapisano politykę retencji: $RETENTION_DAYS dni."

    if [ "$RETENTION_DAYS" -gt 0 ]; then
        CRON_RODO="0 4 * * * cd $(pwd) && docker compose exec -T web python manage.py rodo_cleanup > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "rodo_cleanup"; echo "$CRON_RODO") | crontab -
        msg_info "Dodano automatyczne zadanie Crona (4:00 rano) dla RODO."
    fi
}

module_docker_start() {
    msg_header "Inicjalizacja Środowiska Enterprise (Docker GHCR)"
    read -p "Pobrać i uruchomić system z chmury? [T/n]: " RUN_DOCKER
    RUN_DOCKER=${RUN_DOCKER:-T}

    if [[ ! "$RUN_DOCKER" =~ ^[TtYy]$ ]]; then
        msg_succ "Konfiguracja zakończona. Uruchom system ręcznie komendą: docker compose up -d"
        return
    fi

    msg_info "Pobieranie skompilowanego obrazu aplikacji (GHCR)..."
    docker compose pull
    
    msg_info "Uruchamianie środowiska..."
    docker compose up -d
    
    msg_info "Oczekiwanie na połączenie z bazą danych..."
    sleep 5
    
    msg_info "Aplikowanie wdrożeń i migracji..."
    docker compose exec -T web python manage.py migrate

    msg_info "Zbieranie i mapowanie plików statycznych..."
    docker compose exec -T web python manage.py collectstatic --noinput

    msg_header "APLIKACJA JEST GOTOWA!"
    msg_warn "Aby utworzyć konto SuperAdmina (jeśli to nowa instancja bazy), wpisz:"
    echo -e "${YELLOW}docker compose exec -it web python manage.py createsuperuser${NC}"
}

# ==============================================================================
# GŁÓWNY BLOK WYKONAWCZY (Sterowanie logiką)
# ==============================================================================

module_init
module_ssl
module_network
module_smtp
module_database
module_backups
module_rodo
module_docker_start