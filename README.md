# PPLv2 - Pilgrimage Management System

PPLv2 is a modular, Django-based web application built to manage the logistics, registration, and daily operations of a large-scale walking pilgrimage. 

It is designed to be deployed either on a local network (field server) or a public cloud, replacing paper-based processes with a secure, GDPR-compliant digital workflow.

## 📦 What this deploys

This repo has no application code of its own — it's the installer for
**PPLv2**, a Django application that runs a walking pilgrimage's
registration, payments, vehicle passes, meals, accommodation,
bus/homecoming logistics, and reporting. For what the application
actually does — its modules, features, and how roles/permissions apply to
each — see the [PPLv2-App README](https://github.com/Netulo/PPLv2-App#readme)
and its `docs/ARCHITECTURE.md`. What follows here is the deployment
surface: how the app is packaged, installed, updated, and kept backed up.

## 🛠 Tech Stack

* **Backend**: Python 3.11, Django 5.2
* **Database**: PostgreSQL 15
* **Cache & Rate Limiting**: Redis (Alpine)
* **Frontend**: Bootstrap 5, Vanilla JS, TomSelect, Flatpickr
* **Infrastructure**: Docker, Docker Compose, Nginx, Gunicorn
* **Image Distribution:** GitHub Container Registry (GHCR)

### Containers (`docker-compose.yml`)

| Service | Role |
|---|---|
| `web` | The application image (`ghcr.io/netulo/pplv2:${APP_VERSION}`, `stable` or `beta` channel). On every start, an entrypoint applies pending migrations and collects static files before serving traffic. |
| `db` | PostgreSQL 15. Skipped if `module_database` was configured to use an external database instead. |
| `redis` | Cache, sessions, and rate-limiting backend. |
| `nginx` | Terminates 80/443, serves static files, holds the rendered config from `./nginx`. |
| `certbot` | Not a persistent process — invoked on demand (`docker compose run --rm certbot ...`) to issue/renew the Let's Encrypt certificate. Shows `Exited (0)` after `docker compose up -d`; that's expected. |
| `watchtower` | Opt-in auto-updater (`module_updates`), off by default — only started when the `auto-update` Compose profile is enabled. |

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
BOOTSTRAP_SCRIPT=$(mktemp) && curl -sSL https://raw.githubusercontent.com/Netulo/PPLv2-Infra/main/scripts/bootstrap.sh -o "$BOOTSTRAP_SCRIPT" && sudo bash "$BOOTSTRAP_SCRIPT"
```

### What does the wizard (`setup.sh`) do?
During installation, the system will ask for key environment parameters:
* **Network Security:** Choice between a public server (requires a domain name) and a laptop on the road. In field mode, the system automatically configures mDNS (Avahi), making the application available on the local network at `machine-name.local` and `ppl.local`.
* **SSL Certificates:** Field mode gets a self-signed certificate for local HTTPS. Public-domain mode automatically requests and renews a real, browser-trusted certificate from Let's Encrypt (falls back to self-signed if issuance ever fails, e.g. DNS not pointed at the server yet).
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
3. **Auto-Deploy:** If auto-updates were enabled during setup (`module_updates`), **Watchtower** polls GHCR on the target server and, when it finds a new image, pulls it and restarts the `web` container. On every container start (including this one), an entrypoint script applies pending database migrations and collects static files before the app starts serving traffic. A cron job also re-runs `docker compose pull && docker compose up -d` on server boot, so a machine that was off catches up on the latest image as soon as it's back online.

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
* **Check whether the server is up to date** (this repo, the `web` image,
  and Watchtower, in one pass instead of checking each by hand):
  `bash scripts/status.sh`
* **Migrate an old (pre-PPLv2) database export into this system:**
  `bash scripts/import_pilgrims.sh <folder-with-legacy-CSV-export>` — copies
  the export into the `web` container, runs the legacy `import_pilgrims`
  command, then deletes the in-container copy. The host-side copy you
  point it at is real PESEL/PII data and is **not** deleted automatically;
  remove it yourself once the import is verified.

---

## 💾 Backups and Retention

During installation, the wizard configures CRON tasks directly in the operating system:
* **Smart Backup:** A database backup is created daily at night in the `./backups` folder (bind-mounted from the `web` container to the install directory, so it survives redeploys and auto-updates). If the Cloud module is configured, the copy is additionally uploaded to Google Cloud Storage.
* **GDPR Cleanup:** A script periodically removes personal data of pilgrims older than the defined retention time (default 3 years), maintaining compliance with accounting standards.
* **Session Cleanup:** Regular removal of expired access tokens.

Need a copy on a USB drive/external disk (e.g. before a risky operation)?
Run `scripts/export_backups.sh <destination>` (or menu option 13) — it reads
directly from the host's `./backups` folder, since a USB mount point isn't
visible from inside the `web` container.

**Encryption keys (`.env`) are backed up separately, manually, on purpose.**
`CRYPTOGRAPHY_KEY`/`PESEL_HASH_KEY` decrypt every PII field in the database
backups above — if a copy of `.env` ever ended up in the same place as those
backups, anyone who stole that one location would get both the encrypted
data and the key to read it. Right after setup generates these keys, run
`scripts/export_env_backup.sh <destination>` (or menu option 12 in
`setup.sh`) and store the result somewhere the database backup pipeline has
no access to (password manager, safe, separate storage account) — never the
same GCS bucket or drive.