# PPLv2 - System Zarządzania Pielgrzymką

PPLv2 to modułowa aplikacja internetowa oparta na frameworku Django, stworzona do zarządzania logistyką, rejestracją i codziennymi operacjami dużej pieszej pielgrzymki. 

System jest przystosowany do wdrożenia zarówno w sieci lokalnej (serwer w trasie), jak i w chmurze publicznej. Jego głównym celem jest cyfryzacja i automatyzacja procesów papierowych, przy jednoczesnym zachowaniu pełnej zgodności z RODO.

## 📦 Główne Moduły

System podzielony jest na niezależne aplikacje Django, odpowiadające za konkretne domeny logiczne:

* **`pilgrims` (Pielgrzymi)**: Rdzeń systemu. Obsługuje rejestrację, inteligentne wyszukiwanie po PESEL/ID, śledzenie płatności oraz logowanie zgód RODO.
* **`vehicles` (Pojazdy)**: Wydawanie przepustek samochodowych, zarządzanie danymi kierowców i opłatami.
* **`accommodations` (Noclegi)**: Przydział kwater, śledzenie pojemności baz noclegowych i logistyka.
* **`meals` (Posiłki)**: Zarządzanie dziennym jadłospisem i wydawaniem porcji.
* **`homecoming` (Powroty)**: Rezerwacja biletów autokarowych. Posiada ścisłe limity miejsc, blokadę "overbookingu" oraz automatyczną listę rezerwową.
* **`reports` & `dashboard` (Raporty)**: Analityka w czasie rzeczywistym, podsumowania finansowe oraz system opinii (feedback) dla wolontariuszy.
* **`accounts` (Konta)**: Rozbudowany model użytkownika oparty o RBAC (Role-Based Access Control). Gwarantuje, że wolontariusze mają dostęp tylko do danych niezbędnych do wykonania ich zadania.

## 🛠 Technologie

* **Backend**: Python 3.11, Django 5.x
* **Baza danych**: PostgreSQL 15
* **Cache i Limitowanie zapytań**: Redis (Alpine)
* **Frontend**: Bootstrap 5, Vanilla JS, TomSelect, Flatpickr
* **Infrastruktura**: Docker, Docker Compose, Nginx, Gunicorn
* **Dystrybucja Obrazów:** GitHub Container Registry (GHCR)

## 🔒 Bezpieczeństwo i Zgodność z RODO

Przetwarzanie danych wrażliwych (PESEL, telefony, adresy) wymaga rygorystycznych środków ostrożności:
* **Szyfrowanie bazy (Encryption at Rest)**: Wrażliwe pola w bazie danych są szyfrowane kryptograficznie za pomocą `django-cryptography`.
* **Minimalizacja danych i Prawo do bycia zapomnianym**: Usunięcie profilu użytkownika ("twarde" usunięcie) czyści dane wrażliwe z relacji (`SET_NULL`), nie psując przy tym spójności księgowej i finansowej systemu.
* **Ochrona Brute-force**: Biblioteka `django-axes` (wspierana przez Redis) blokuje wielokrotne próby odgadnięcia hasła.
* **Audyt**: Krytyczne modele dziedziczą po klasie `AuditableModel`, która zapisuje, kto i kiedy utworzył lub zmodyfikował dany wpis.

## 🚀 Instalacja (Automatyczny Instalator)

System wykorzystuje model "Enterprise Deploy". Kod źródłowy nie jest budowany na serwerze docelowym. Zamiast tego, serwer pobiera gotowy, skompilowany obraz Dockera z prywatnego rejestru GitHub.

### Wymagania wstępne:
1. Czysty system operacyjny Linux (Zalecane Ubuntu/Debian).
2. Połączenie z internetem.
3. **GitHub Personal Access Token (PAT)** – wymagany do pobrania kodu konfiguracyjnego oraz obrazu Dockera. Token musi posiadać uprawnienia:
   - `repo` (dostęp do prywatnych repozytoriów)
   - `read:packages` (pobieranie obrazów z GHCR)

### Uruchomienie Instalacji
Wklej poniższą komendę w terminalu na nowej maszynie. Skrypt zainstaluje Dockera, przygotuje środowisko i uruchomi kreator konfiguracji:

```bash
BOOTSTRAP_SCRIPT=$(mktemp) && curl -sSL https://raw.githubusercontent.com/Netulo/PPLv2-Infra/main/scripts/bootstrap.sh -o "$BOOTSTRAP_SCRIPT" && sudo bash "$BOOTSTRAP_SCRIPT"
```

### Co robi kreator (`setup.sh`)?
Podczas instalacji system zapyta o kluczowe parametry środowiska:
* **Zabezpieczenia sieciowe:** Wybór między serwerem publicznym (wymaga podania domeny) a laptopem w trasie. W trybie trasy system automatycznie konfiguruje mDNS (Avahi), dzięki czemu aplikacja będzie dostępna w sieci lokalnej pod adresem `nazwa-komputera.local` oraz `ppl.local`.
* **Certyfikaty SSL:** Tryb trasy dostaje certyfikat self-signed dla lokalnego HTTPS. Tryb domeny publicznej automatycznie żąda i odnawia prawdziwy certyfikat zaufany przez przeglądarki z Let's Encrypt (w razie niepowodzenia wydania - np. domena jeszcze nie wskazuje na serwer - zostaje na self-signed).
* **Baza Danych:** Możliwość wyboru lokalnego kontenera PostgreSQL lub podpięcia zewnętrznej bazy (wtedy lokalny kontener jest automatycznie wygaszany).
* **Automatyzacja (Cron):** Instalacja skryptów czyszczących stare sesje, wykonujących backupy oraz realizujących politykę retencji danych RODO.

---

## 🌱 Dane Początkowe (Starterpack Wdrożeniowy)

Po `migrate` i `createsuperuser` należy zaseedować dane początkowe
specyficzne dla lokalizacji — parafie/miasta, służby, zawody/statusy,
cennik wpisowego i usług, role RBAC oraz ustawienia systemowe — jedną,
idempotentną komendą uruchamianą w kontenerze `web`:

```bash
docker compose exec web python manage.py init_starterpack --profile <nazwa>
```

### Profile wdrożenia
Każda lokalizacja pielgrzymki jest inna — inne parafie, inny skład służb,
czasem inne kategorie uczestników (zawody) z innymi opłatami wpisowymi.
Dane te są przechowywane per-lokalizacja w repozytorium aplikacji
(`PPLv2-App`), w katalogu `pilgrims/fixtures/deployments/<nazwa>/`:
* `parishes.csv` — `city,parish,additional_information`
* `duties.csv` — `name,sort_order`
* `occupations.csv` — `name,registration_price`

`--profile` domyślnie to `default` (przykładowy, działający profil
dołączony do repozytorium aplikacji). Aby uruchomić nową lokalizację,
skopiuj ten folder pod nową nazwą i zmodyfikuj trzy pliki CSV, a następnie
uruchom `init_starterpack --profile <nazwa>`. Wszystkie trzy pliki są
wyłącznie dopisywalne (additive-only) — ponowne uruchomienie po edycji
nigdy nie usuwa istniejących wpisów, więc komendę można bezpiecznie
uruchamiać wielokrotnie w miarę uzupełniania listy w trakcie sezonu.

### Migracja parafii/miast ze starego backupu bazy danych
Jeśli masz eksport ze starej bazy danych (pliki CSV odczytywane przez
historyczną komendę migracyjną `import_pilgrims`), przekonwertuj listę
Parafii/Miast do nowego formatu zamiast przepisywać ją ręcznie:

```bash
docker compose exec web python manage.py export_legacy_parishes \
  --cities /sciezka/do/bck_parishCities_*.csv \
  --parishes /sciezka/do/bck_parishes_*.csv \
  --out pilgrims/fixtures/deployments/<nazwa>/parishes.csv
```
Komenda wyłącznie czyta/zapisuje pliki — nigdy nie dotyka bazy danych —
więc przejrzyj wynikowy plik CSV przed uruchomieniem `init_starterpack`.

### Co jest uniwersalne, a co per-lokalizacja
* **Per-lokalizacja** (z powyższych CSV): parafie/miasta, służby,
  zawody/statusy wraz z ich opłatą wpisową.
* **Uniwersalne, identyczne dla każdego wdrożenia**: role RBAC, ceny
  "systemowe" (wyżywienie, noclegi, przepustki samochodowe, bagaż, zniżki —
  różni się tylko domyślna *kwota*, edytowalna później w panelu cennika)
  oraz ustawienia systemowe (edytowalne później w panelu ustawień). Są one
  zaseedowane automatycznie przez `init_starterpack` i nigdy nie wymagają
  osobnego pliku per wdrożenie.

---

## 🔄 Ciągłe Wdrażanie i Aktualizacje (CI/CD)

Projekt wykorzystuje GitHub Actions do pełnej automatyzacji wydań.

1. **Push do gałęzi `main`:** Każda zmiana w kodzie głównym uruchamia proces na serwerach GitHuba.
2. **Budowanie obrazu:** GitHub kompiluje nową wersję aplikacji i wysyła gotowy obraz do rejestru GHCR.
3. **Auto-Deploy:** Jeśli auto-aktualizacje zostały włączone podczas instalacji (`module_updates`), **Watchtower** odpytuje GHCR na docelowym serwerze i po wykryciu nowego obrazu pobiera go oraz restartuje kontener `web`. Przy każdym starcie kontenera (również tym) skrypt startowy aplikuje oczekujące migracje bazy danych i zbiera pliki statyczne, zanim aplikacja zacznie obsługiwać ruch. Zadanie cron uruchamiane po restarcie serwera ponownie wykonuje `docker compose pull && docker compose up -d`, dzięki czemu maszyna, która była wyłączona, po ponownym uruchomieniu sama dociąga najnowszy obraz.

### Ręczna aktualizacja (Opcjonalnie)
Jeżeli z jakiegoś powodu CI/CD nie zadziała, system można zaktualizować ręcznie jedną komendą w folderze projektu:
```bash
docker compose pull && docker compose up -d
```

---

## 🛠 Zarządzanie Systemem

Wszystkie usługi zarządzane są przez narzędzie Docker Compose. Główne komendy (wykonywane w folderze `/opt/ppl/PPLv2`):

* **Sprawdzenie statusu kontenerów:** 
  `docker compose ps`
* **Podgląd logów aplikacji w czasie rzeczywistym:** 
  `docker compose logs -f web`
* **Tworzenie konta Super Administratora:** 
  `docker compose exec web python manage.py createsuperuser`
* **Wejście do powłoki (shell) bazy danych:**
  `docker compose exec db psql -U pplv2_user -d pplv2_db`

---

## 💾 Kopie Zapasowe i Retencja

Podczas instalacji kreator konfiguruje zadania CRON bezpośrednio w systemie operacyjnym:
* **Inteligentny Backup:** Kopia zapasowa bazy danych tworzona jest codziennie w nocy w folderze `./backups`. Jeśli skonfigurowano moduł Cloud, kopia wysyłana jest dodatkowo do Google Cloud Storage.
* **RODO Cleanup:** Skrypt cyklicznie usuwa dane osobowe pielgrzymów starsze niż zdefiniowany czas retencji (domyślnie 3 lata), zachowując zgodność ze standardami księgowymi.
* **Czyszczenie sesji:** Regularne usuwanie wygasłych tokenów dostępu