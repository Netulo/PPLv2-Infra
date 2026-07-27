# PPLv2 - Pilgrimage Management System

PPLv2 is a modular, Django-based web application built to manage the logistics, registration, and daily operations of a large-scale walking pilgrimage. 

It is designed to be deployed either on a local network (field server) or a public cloud, replacing paper-based processes with a secure, GDPR-compliant digital workflow.

## 📦 Core Modules

The system is split into independent Django apps handling specific domain logic:

* **`pilgrims`**: Core registration. Handles personal data, PESEL/ID-based smart search, payment tracking, and GDPR consent logging.
* **`vehicles`**: Issues and tracks car passes, driver details, and parking fees.
* **`accommodations`**: Manages host allocations, capacity tracking, and overnight stay logistics.
* **`meals`**: Tracks dietary requirements, daily menus, and meal orders.
* **`homecoming`**: Bus ticket reservation system. Features strict capacity limits, overbooking prevention, and automated waitlist handling.
* **`reports` & `dashboard`**: Real-time analytics, financial summaries, and a volunteer feedback system.
* **`accounts`**: Custom user model and Role-Based Access Control (RBAC). Ensures volunteers only see the data relevant to their specific duty.

## 🛠 Tech Stack

* **Backend**: Python 3.11, Django 5.2
* **Database**: PostgreSQL 15
* **Cache & Rate Limiting**: Redis (Alpine)
* **Frontend**: Bootstrap 5, Vanilla JS, TomSelect, Flatpickr
* **Infrastructure**: Docker, Docker Compose, Nginx, Gunicorn
* **Image Distribution:** GitHub Container Registry (GHCR)

## 🔒 Security & GDPR (RODO) Compliance

Handling sensitive personal data (PESEL, phone numbers, addresses) requires strict compliance. The system implements:
* **Encryption at Rest**: Sensitive database fields are encrypted using `django-cryptography`.
* **Data Minimization & Deletion**: The system supports the "Right to be forgotten". Deleting a user nullifies sensitive links (`SET_NULL`) without breaking financial integrity.
* **Brute-force Protection**: `django-axes` backed by Redis blocks repeated failed login attempts.
* **Auditing**: Critical models inherit from an `AuditableModel` to track who created or modified records and when.

## 🚀 Installation (Automated Installer)

The system utilizes an "Enterprise Deploy" model. The source code is not built on the target server. Instead, the server pulls a ready, compiled Docker image from the private GitHub registry.

### Prerequisites:
1. Clean Linux OS (Ubuntu/Debian recommended).
2. Internet connection.
3. **GitHub Personal Access Token (PAT)** – required to download the configuration code and the Docker image. The token must have `repo` (access to private repositories) and `read:packages` (downloading images from GHCR) permissions.

### Running the Installation
Paste the following command in the terminal on a new machine. The script will install Docker, prepare the environment, and launch the configuration wizard:

```bash
curl -sSL https://gist.githubusercontent.com/Netulo/2b9e92f8096049d665552c9cca90b366/raw/bootstrap.sh?v=3 -o /tmp/bootstrap.sh && sudo bash /tmp/bootstrap.sh
```

### What does the wizard (`setup.sh`) do?
During installation, the system will ask for key environment parameters:
* **Network Security:** Choice between a public server (requires a domain name) and a laptop on the road. In field mode, the system automatically configures mDNS (Avahi), making the application available on the local network at `machine-name.local` and `ppl.local`.
* **SSL Certificates:** Automatic generation of self-signed certificates for secure local connections (HTTPS).
* **Database:** Option to choose a local PostgreSQL container or connect to an external database (in which case the local container is automatically disabled).
* **Automation (Cron):** Installation of scripts for clearing expired sessions, executing backups, and enforcing the GDPR data retention policy.

---

## 🌱 Initial Data (Deployment Starterpack)

After `migrate` and `createsuperuser`, seed the location-specific reference
data — parishes/cities, duties, occupations, registration/service prices,
RBAC roles, and system settings — with a single idempotent command run
inside the `web` container:

```bash
docker compose exec web python manage.py init_starterpack --profile <slug>
```

### Deployment profiles
Every pilgrimage location is different — different parishes, a different
duty roster, sometimes different participant categories (occupations) with
different registration fees. This is captured per-location in the **app
repo** (`PPLv2-App`), under `pilgrims/fixtures/deployments/<slug>/`:
* `parishes.csv` — `city,parish,additional_information`
* `duties.csv` — `name,sort_order`
* `occupations.csv` — `name,registration_price`

`--profile` defaults to `default` (a working example profile shipped in the
app repo). To stand up a new location, copy that folder to a new slug and
edit the three CSVs, then run `init_starterpack --profile <slug>`. All
three files are additive-only — rerunning after editing them never deletes
existing rows, so it's safe to run repeatedly as the list grows across a
season.

### Migrating parishes/cities from an old database backup
If you have a legacy database export (the CSVs the historic
`import_pilgrims` migration command reads), convert its Parish/City lists
into the new format instead of retyping them by hand:

```bash
docker compose exec web python manage.py export_legacy_parishes \
  --cities /path/to/bck_parishCities_*.csv \
  --parishes /path/to/bck_parishes_*.csv \
  --out pilgrims/fixtures/deployments/<slug>/parishes.csv
```
This command only reads/writes files — it never touches the database — so
review the generated CSV before running `init_starterpack`.

### What's universal vs. per-location
* **Per-location** (from the CSVs above): parishes/cities, duties,
  occupations and their registration fee.
* **Universal, identical on every deployment**: RBAC roles, "system" prices
  (meals, accommodation, vehicle pass, baggage, discounts — only their
  *default amount* differs, editable afterward in the pricing admin), and
  system settings (editable afterward in the settings admin). These are
  seeded automatically by `init_starterpack` and never need a per-deployment
  file.

---

## 🔄 Continuous Deployment and Updates (CI/CD)

The project uses GitHub Actions for fully automated releases.

1. **Push to `main` branch:** Every change in the main codebase triggers a workflow on GitHub servers.
2. **Image Build:** GitHub compiles the new version of the application and pushes the ready image to the GHCR registry.
3. **Auto-Deploy:** Thanks to the installed agent (Self-Hosted Runner), the target server/laptop automatically detects the new version, pulls the image (`docker compose pull`), applies migrations, and seamlessly restarts the application with no noticeable downtime.

### Manual Update (Optional)
If for any reason CI/CD fails, the system can be updated manually with a single command in the project folder:
```bash
docker compose pull && docker compose up -d
```

---

## 🛠 System Management

All services are managed via Docker Compose. Main commands (executed in the `/opt/ppl/PPLv2` directory):

* **Check container status:** 
  `docker compose ps`
* **View real-time application logs:** 
  `docker compose logs -f web`
* **Create a Super Administrator account:** 
  `docker compose exec web python manage.py createsuperuser`
* **Enter the database shell:**
  `docker compose exec db psql -U pplv2_user -d pplv2_db`

---

## 💾 Backups and Retention

During installation, the wizard configures CRON tasks directly in the operating system:
* **Smart Backup:** A database backup is created daily at night in the `./backups` folder. If the Cloud module is configured, the copy is additionally uploaded to Google Cloud Storage.
* **GDPR Cleanup:** A script periodically removes personal data of pilgrims older than the defined retention time (default 3 years), maintaining compliance with accounting standards.
* **Session Cleanup:** Regular removal of expired access tokens.