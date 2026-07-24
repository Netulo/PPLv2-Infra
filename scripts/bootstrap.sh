#!/bin/bash
# ==============================================================================
# PPLv2 - BOOTSTRAP INSTALLER (One-Liner)
# ==============================================================================
set -e # Przerwij skrypt, jeśli wystąpi jakikolwiek krytyczny błąd

# Kolory dla czytelności
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}        INICJALIZACJA SYSTEMU PPLv2 (AUTO-INSTALL)    ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 1. Zabezpieczenie: Sprawdzenie, czy skrypt odpalono jako administrator (root)
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[BŁĄD] Uruchom ten skrypt z uprawnieniami root (dodaj sudo na początku)${NC}"
  exit 1
fi

# 2. Zbieranie danych uwierzytelniających
echo -e "${YELLOW}Aby pobrać system, potrzebujesz tokenu GitHub (Personal Access Token).${NC}"
read -p "Podaj nazwę użytkownika GitHub: " GIT_USER < /dev/tty
read -sp "Wklej swój GitHub Token (ghp_...): " GIT_TOKEN < /dev/tty
echo ""

# 3. Instalacja niezbędnych fundamentów systemowych (tryb cichy)
echo -e "\n${GREEN}[1/5] Instalowanie fundamentów systemowych (curl, git, avahi)...${NC}"
apt-get -qq update >/dev/null
apt-get -qq install -y curl git avahi-daemon >/dev/null

# 4. Instalacja Dockera (pobiera oficjalny skrypt instalacyjny, jeśli Dockera jeszcze nie ma)
if ! command -v docker &> /dev/null; then
    echo -e "${GREEN}[2/5] Instalowanie środowiska Docker Engine...${NC}"
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
else
    echo -e "${GREEN}[2/5] Docker jest już zainstalowany, pomijam ten krok.${NC}"
fi

# 5. Logowanie do chmury (GitHub Container Registry)
echo -e "${GREEN}[3/5] Autoryzacja w chmurze GitHub (GHCR)...${NC}"
if echo "$GIT_TOKEN" | docker login ghcr.io -u "$GIT_USER" --password-stdin >/dev/null 2>&1; then
    echo -e "${GREEN} -> Zalogowano pomyślnie!${NC}"
else
    echo -e "${RED}[BŁĄD] Nieprawidłowy token lub brak uprawnień read:packages!${NC}"
    exit 1
fi

# 6. Klonowanie najnowszych plików konfiguracyjnych i skryptów (z uwierzytelnieniem)
INSTALL_DIR="/opt/ppl/PPLv2"
echo -e "${GREEN}[4/5] Pobieranie struktury plików do ${INSTALL_DIR}...${NC}"

if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW} -> Katalog już istnieje. Aktualizuję pliki...${NC}"
    cd "$INSTALL_DIR"
    git remote set-url origin "https://${GIT_USER}:${GIT_TOKEN}@github.com/Netulo/PPLv2.git"
    git fetch origin main
    git reset --hard origin/main >/dev/null
else
    echo -e "${YELLOW} -> Pobieranie repozytorium...${NC}"
    git clone "https://${GIT_USER}:${GIT_TOKEN}@github.com/Netulo/PPLv2.git" "$INSTALL_DIR" >/dev/null
fi

# 7. Płynne przejście do kreatora środowiska
echo -e "${GREEN}[5/5] Uruchamianie głównego konfiguratora (setup.sh)...${NC}"
cd "$INSTALL_DIR"
chmod +x scripts/setup.sh

echo -e "${BLUE}======================================================${NC}"
# Wywołanie Twojego skryptu setup.sh (który za chwilę dostosujemy)
./scripts/setup.sh