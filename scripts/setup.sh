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
    chmod 600 "$ENV_FILE" # .env holds SECRET_KEY/DB/SMTP passwords - never world-readable
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
        chmod 600 "$BACKUP_ENV" # backup contains the same secrets as .env
        msg_info "Wykryto istniejący plik $ENV_FILE. Kopia zapasowa: $BACKUP_ENV"
    else
        echo "# Wygenerowano: $(date)" > "$ENV_FILE"
        chmod 600 "$ENV_FILE"
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

    # CRYPTOGRAPHY_KEY/PESEL_HASH_KEY protect PII at rest - unlike SECRET_KEY,
    # there is deliberately no "regenerate?" prompt for these: changing either
    # one after real data exists makes that data permanently unreadable
    # (encrypted fields can't be decrypted, PESEL hash lookups stop matching).
    # Generate once on first install, then always keep silently.
    NEW_KEYS_GENERATED=false
    if [ -z "$(get_env_var CRYPTOGRAPHY_KEY)" ]; then
        set_env_var CRYPTOGRAPHY_KEY "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)"
        msg_succ "Wygenerowano CRYPTOGRAPHY_KEY (klucz szyfrowania danych osobowych)."
        NEW_KEYS_GENERATED=true
    fi
    if [ -z "$(get_env_var PESEL_HASH_KEY)" ]; then
        set_env_var PESEL_HASH_KEY "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)"
        msg_succ "Wygenerowano PESEL_HASH_KEY (klucz haszowania numerów PESEL)."
        NEW_KEYS_GENERATED=true
    fi
    if [ "$NEW_KEYS_GENERATED" = true ]; then
        msg_warn "WAŻNE: Zrób teraz bezpieczną kopię .env (opcja 11 w menu, lub 'scripts/export_env_backup.sh <ścieżka>')."
        msg_warn "Przechowuj ją GDZIE INDZIEJ niż backupy bazy danych - w przeciwnym razie ktoś, kto ukradnie"
        msg_warn "jedno miejsce (np. bucket GCS), ukradnie też klucz do odszyfrowania wszystkich danych osobowych."
    fi
}

# Renders nginx/default.conf from the template using the host/domain choice
# (module_network) and the certificate paths (module_ssl) already persisted
# in .env. Must run after both have set their values at least once - falls
# back to safe defaults with a warning if either is still missing.
render_nginx_config() {
    local server_name cert_path key_path
    server_name=$(get_env_var NGINX_SERVER_NAME)
    cert_path=$(get_env_var SSL_CERT_PATH)
    key_path=$(get_env_var SSL_KEY_PATH)

    if [ -z "$server_name" ]; then
        msg_warn "Brak skonfigurowanego hosta/domeny (uruchom najpierw opcję 4 - Sieć/domena) - używam tymczasowo 'localhost'."
        server_name="localhost"
    fi
    if [ -z "$cert_path" ] || [ -z "$key_path" ]; then
        cert_path="/etc/nginx/certs/server.crt"
        key_path="/etc/nginx/certs/server.key"
    fi

    msg_info "Aktualizacja konfiguracji Nginx..."
    sed -e "s#PLACEHOLDER_DOMAIN#$server_name#g" \
        -e "s#PLACEHOLDER_SSL_CERT#$cert_path#g" \
        -e "s#PLACEHOLDER_SSL_KEY#$key_path#g" \
        nginx/nginx.conf.template > nginx/default.conf
    msg_succ "Konfiguracja Nginx zaktualizowana."
}

module_ssl_selfsigned() {
    mkdir -p nginx/certs
    if [ ! -f nginx/certs/server.crt ]; then
        msg_info "Generowanie certyfikatów self-signed..."
        # Browsers have ignored the CN field for validation since ~2017 and
        # require a matching Subject Alternative Name instead - without SAN
        # entries here, the cert fails hostname validation no matter which
        # of localhost/127.0.0.1/mDNS-name/LAN-IP the browser was actually
        # pointed at (even after the cert is manually trusted). Build the
        # SAN list from NGINX_SERVER_NAME (set by module_network, which
        # always runs before this) so every way this box is reachable is
        # covered; fall back to localhost if it's somehow still unset.
        local server_name entry san_entries="" openssl_err
        server_name=$(get_env_var NGINX_SERVER_NAME)
        server_name=${server_name:-localhost}
        # NGINX_SERVER_NAME is meant to be space-separated, but its sibling
        # ALLOWED_HOSTS is comma-separated - a manual .env edit that copies
        # the wrong convention (as happened once already) leaves a
        # comma-joined entry with no DNS:/IP: prefix, which openssl rejects
        # outright. Normalize commas to spaces so either delimiter works.
        server_name=${server_name//,/ }
        for entry in $server_name; do
            if [[ "$entry" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                san_entries="${san_entries}IP:$entry,"
            else
                san_entries="${san_entries}DNS:$entry,"
            fi
        done
        san_entries=${san_entries%,}

        if ! openssl_err=$(openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout nginx/certs/server.key \
          -out nginx/certs/server.crt \
          -subj "/C=PL/ST=PPL/L=Trasa/O=PPL_Server/CN=localhost" \
          -addext "subjectAltName=$san_entries" 2>&1); then
            rm -f nginx/certs/server.crt nginx/certs/server.key
            msg_err "Generowanie certyfikatu nie powiodło się: $openssl_err"
            return 1
        fi
        if ! openssl x509 -in nginx/certs/server.crt -noout -text >/dev/null 2>&1; then
            rm -f nginx/certs/server.crt nginx/certs/server.key
            msg_err "Wygenerowany certyfikat nie przeszedł walidacji (openssl x509 nie potrafi go odczytać) - usunięto niepoprawny plik."
            return 1
        fi

        msg_succ "Certyfikaty zapisane w nginx/certs/ (SAN: $san_entries)."
    else
        msg_succ "Certyfikaty self-signed już istnieją, pomijam. (Usuń nginx/certs/server.crt, aby wygenerować nowe.)"
    fi
}

# Requests/renews the real Let's Encrypt certificate via the HTTP-01 webroot
# challenge. Requires nginx to already be running and serving
# /.well-known/acme-challenge/ from the shared certbot_www volume (true once
# module_docker_start has done `docker compose up -d`, or on any later
# re-run against an already-deployed install) - never call this before that.
# Safe to call repeatedly: certbot skips re-issuing a still-valid certificate.
issue_letsencrypt_cert() {
    local domain email
    domain=$(get_env_var DOMAIN_NAME)
    email=$(get_env_var LETSENCRYPT_EMAIL)

    if [ -z "$domain" ] || [ -z "$email" ]; then
        msg_err "Brak domeny lub e-maila do Let's Encrypt - pomijam wydanie certyfikatu."
        return 1
    fi

    msg_info "Żądanie certyfikatu Let's Encrypt dla $domain..."
    if docker compose run --rm certbot certonly \
        --webroot -w /var/www/certbot \
        -d "$domain" --email "$email" --agree-tos --no-eff-email --non-interactive; then
        msg_succ "Certyfikat Let's Encrypt gotowy dla $domain."
        set_env_var SSL_CERT_PATH "/etc/letsencrypt/live/$domain/fullchain.pem"
        set_env_var SSL_KEY_PATH "/etc/letsencrypt/live/$domain/privkey.pem"
        render_nginx_config
        docker compose exec -T nginx nginx -s reload 2>/dev/null || true
        register_certbot_renewal_cron
        return 0
    else
        msg_err "Wydanie certyfikatu Let's Encrypt nie powiodło się - serwer zostaje na certyfikacie self-signed."
        msg_warn "Najczęstsze przyczyny: domena $domain jeszcze nie wskazuje na ten serwer (sprawdź rekord DNS A/AAAA), port 80 zablokowany przez firewall/router, albo limit Let's Encrypt (5 wydań/tydzień na domenę)."
        msg_warn "Popraw DNS/firewall, a następnie uruchom ponownie opcję '2) Certyfikaty SSL' z menu."
        return 1
    fi
}

register_certbot_renewal_cron() {
    msg_info "Rejestrowanie odnawiania certyfikatu w cron..."
    CRON_CERTBOT_CMD="30 3 * * * cd $(pwd) && docker compose run --rm certbot renew --webroot -w /var/www/certbot --quiet && docker compose exec -T nginx nginx -s reload > /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "$CRON_CERTBOT_CMD") | crontab -
    msg_succ "Zadanie odnawiania certyfikatu Let's Encrypt dodane do crontab (codziennie o 3:30)."
}

# Only meaningful after module_docker_start has brought nginx up at least
# once - called from the menu (re-runs) and from module_docker_start itself
# (first install).
maybe_issue_letsencrypt_cert() {
    if [ "$(get_env_var SSL_MODE)" == "letsencrypt" ]; then
        issue_letsencrypt_cert
    fi
}

module_ssl() {
    msg_header "Certyfikaty SSL"
    local env_type domain

    # A self-signed cert is always kept on hand, even in Let's Encrypt mode:
    # it's what nginx serves as the *initial* certificate before the ACME
    # challenge can succeed (nginx must already be listening on 443 with a
    # valid cert for the HTTP-01 flow in issue_letsencrypt_cert to run), and
    # it's the automatic fallback if issuance/renewal ever fails.
    if ! module_ssl_selfsigned; then
        msg_err "Konfiguracja SSL przerwana - certyfikat self-signed nie został wygenerowany."
        return 1
    fi

    env_type=$(get_env_var ENV_TYPE)
    domain=$(get_env_var DOMAIN_NAME)

    if [ "$env_type" == "2" ] && [ -n "$domain" ]; then
        msg_info "Tryb: Let's Encrypt (domena publiczna: $domain)."
        read -p "Adres e-mail do powiadomień Let's Encrypt (wygasanie certyfikatu itp.): " LE_EMAIL < /dev/tty
        if [ -z "$LE_EMAIL" ]; then
            msg_err "E-mail jest wymagany przez Let's Encrypt. Zostaję na certyfikacie self-signed."
            set_env_var SSL_MODE selfsigned
            unset_env_var LETSENCRYPT_EMAIL
        else
            set_env_var SSL_MODE letsencrypt
            set_env_var LETSENCRYPT_EMAIL "$LE_EMAIL"
            msg_info "Prawdziwy certyfikat zostanie wydany automatycznie po uruchomieniu kontenerów (wymaga, aby domena $domain wskazywała już na ten serwer)."
        fi
    else
        set_env_var SSL_MODE selfsigned
        unset_env_var LETSENCRYPT_EMAIL
    fi

    # In selfsigned mode, or in letsencrypt mode before a real cert has ever
    # been issued, nginx serves the self-signed cert. But if a real cert was
    # already issued for this domain (re-running this module against an
    # already-working deployment), keep pointing at it - don't flip nginx
    # back to self-signed and force an avoidable restart/flicker; the
    # renewal check in maybe_issue_letsencrypt_cert handles keeping it fresh.
    CURRENT_CERT_PATH=$(get_env_var SSL_CERT_PATH)
    if [ "$(get_env_var SSL_MODE)" != "letsencrypt" ] || [[ "$CURRENT_CERT_PATH" != "/etc/letsencrypt/live/"* ]]; then
        set_env_var SSL_CERT_PATH "/etc/nginx/certs/server.crt"
        set_env_var SSL_KEY_PATH "/etc/nginx/certs/server.key"
    fi
    render_nginx_config
}

module_network() {
    msg_header "Konfiguracja hosta i domeny"
    CURRENT_HOSTS=$(get_env_var ALLOWED_HOSTS)
    [ -n "$CURRENT_HOSTS" ] && msg_info "Obecne ALLOWED_HOSTS: $CURRENT_HOSTS"

    echo "1) Środowisko lokalne / offline (localhost + IP LAN)"
    echo "2) Serwer docelowy (domena publiczna)"
    read -p "Wybierz typ środowiska [1/2]: " ENV_TYPE < /dev/tty
    set_env_var ENV_TYPE "$ENV_TYPE"

    NGINX_SERVER_NAME=""

    if [ "$ENV_TYPE" == "2" ]; then
        read -p "Podaj domenę (np. system.domena.pl)${CURRENT_HOSTS:+ [obecnie: $CURRENT_HOSTS]}: " DOMAIN_NAME < /dev/tty
        DOMAIN_NAME=${DOMAIN_NAME:-$CURRENT_HOSTS}
        set_env_var ALLOWED_HOSTS "$DOMAIN_NAME"
        set_env_var CSRF_TRUSTED_ORIGINS "https://$DOMAIN_NAME"
        set_env_var DOMAIN_NAME "$DOMAIN_NAME"
        NGINX_SERVER_NAME="$DOMAIN_NAME"
    else
        unset_env_var DOMAIN_NAME
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

        # Anything else this box needs to be reachable as (Tailscale
        # MagicDNS name, a second LAN alias, etc.) belongs here rather than
        # a hand-edit of .env afterwards - a manual edit has no guardrail
        # against ALLOWED_HOSTS' comma convention and NGINX_SERVER_NAME's
        # space convention silently diverging (that mismatch once broke
        # self-signed cert generation for days without anyone noticing).
        # Pre-fill with whatever's already in ALLOWED_HOSTS today, minus the
        # entries this function manages itself, so re-running the wizard
        # doesn't drop a previously-added extra host.
        CURRENT_EXTRA_HOSTS=$(echo "$CURRENT_HOSTS" | tr ',' '\n' | grep -v '^$' | grep -vxF -e "localhost" -e "127.0.0.1" -e "$MDNS_NAME" ${CURRENT_LOCAL_IP:+-e "$CURRENT_LOCAL_IP"} | tr '\n' ' ' | sed 's/ *$//')
        read -p "Dodatkowe nazwy hosta (np. Tailscale MagicDNS), oddzielone spacją${CURRENT_EXTRA_HOSTS:+ [obecnie: $CURRENT_EXTRA_HOSTS]} [ENTER = pomiń]: " EXTRA_HOSTS < /dev/tty
        EXTRA_HOSTS=${EXTRA_HOSTS:-$CURRENT_EXTRA_HOSTS}
        if [ -n "$EXTRA_HOSTS" ]; then
            # Accept commas too (easy to type out of habit) and normalize to
            # both conventions here, once, instead of leaving that to a
            # future manual .env edit.
            for extra in ${EXTRA_HOSTS//,/ }; do
                HOSTS="$HOSTS,$extra"
                TRUSTED="$TRUSTED,https://$extra,http://$extra"
                NGINX_SERVER_NAME="$NGINX_SERVER_NAME $extra"
            done
        fi

        set_env_var ALLOWED_HOSTS "$HOSTS"
        set_env_var CSRF_TRUSTED_ORIGINS "$TRUSTED"
        msg_info "Przypisano mDNS: $MDNS_NAME"
    fi

    set_env_var NGINX_SERVER_NAME "$NGINX_SERVER_NAME"
    msg_succ "Konfiguracja sieciowa zakończona. (Certyfikat/nginx zostaną zaktualizowane w kroku 'Certyfikaty SSL'.)"
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
        read -sp "Hasło SMTP jest już ustawione [ENTER = zachowaj, lub podaj nowe]: " EMAIL_PASS
        echo ""
        EMAIL_PASS=${EMAIL_PASS:-$CURRENT_PASS}
    else
        read -sp "Hasło SMTP: " EMAIL_PASS
        echo ""
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
            read -sp "Hasło zewnętrznej bazy jest już ustawione [ENTER = zachowaj, lub podaj nowe]: " EXT_DB_PASS
            echo ""
            EXT_DB_PASS=${EXT_DB_PASS:-$CURRENT_EXT_PASS}
        else
            read -sp "Hasło zewnętrznej bazy: " EXT_DB_PASS
            echo ""
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
        if ! [[ "$cron_hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
            msg_warn "Błędna godzina. Ustawiono domyślną (3)."
            cron_hour=3
        fi
        read -p "Częstotliwość w dniach [ENTER = 1]: " cron_days
        cron_days=${cron_days:-1}
        if ! [[ "$cron_days" =~ ^[0-9]+$ ]] || [ "$cron_days" -lt 1 ]; then
            msg_warn "Błędna częstotliwość. Ustawiono domyślną (1 dzień)."
            cron_days=1
        fi

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

    echo "1) STABLE - dla serwerów produkcyjnych. Aktualizuje się WYŁĄCZNIE gdy"
    echo "   ktoś świadomie wyda nowy tag (np. v1.2.0) w repo PPLv2-App - Watchtower"
    echo "   nigdy nie wdroży niesprawdzonej zmiany na produkcję."
    echo "2) BETA - dla serwerów testowych. Śledzi każdy push na main w PPLv2-App"
    echo "   bez żadnej bramki - Watchtower wdroży to, co jest na main, gdy tylko"
    echo "   się pojawi. Sporadyczne awarie po aktualizacji to tu oczekiwane"
    echo "   zachowanie (to właśnie po to jest serwer testowy), nie błąd instalacji."
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

    # `docker compose up -d` alone doesn't make an already-running nginx
    # container pick up changes to the bind-mounted nginx/default.conf (only
    # an image/env/volume-list change triggers a recreate) - reload
    # explicitly so network/SSL menu changes actually take effect. Harmless
    # no-op if nginx isn't running yet (e.g. this is the very first run).
    docker compose exec -T nginx nginx -s reload 2>/dev/null || true

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

    if [ "$(get_env_var SSL_MODE)" == "letsencrypt" ]; then
        msg_info "Oczekiwanie na start nginx przed żądaniem certyfikatu Let's Encrypt..."
        sleep 3
        issue_letsencrypt_cert
    fi

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
    module_network
    module_ssl
    module_versioning
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
    echo "11) Backup kluczy .env (ODDZIELNIE od backupów bazy danych)"
    echo "12) Eksport backupów bazy danych na pendrive/dysk zewnętrzny"
    echo " 0) Wyjście"
    read -p "Wybierz opcję: " menu_choice < /dev/tty

    case "$menu_choice" in
        1) run_full_setup ;;
        2) module_ssl && module_apply && maybe_issue_letsencrypt_cert ;;
        3) module_versioning; module_apply --pull ;;
        4) module_network; module_ssl && module_apply && maybe_issue_letsencrypt_cert ;;
        5) module_smtp; module_apply ;;
        6) module_database; module_apply ;;
        7) module_backups; module_apply ;;
        8) module_rodo; module_apply ;;
        9) module_updates; module_apply --pull ;;
        10) module_apply --pull ;;
        11)
            read -p "Ścieżka docelowa (NIE ta sama co backupy bazy danych): " env_backup_dest < /dev/tty
            bash scripts/export_env_backup.sh "$env_backup_dest"
            ;;
        12)
            read -p "Ścieżka docelowa (pendrive/dysk zewnętrzny): " backups_export_dest < /dev/tty
            bash scripts/export_backups.sh "$backups_export_dest"
            ;;
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
