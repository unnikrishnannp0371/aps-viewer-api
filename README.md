# APS Viewer API

A Ruby on Rails API backend for the APS Viewer application. Handles Autodesk Platform Services (APS) authentication, session management, and data access for browsing ACC hubs, projects, folders and files. Generates shareable links for 3D models that can be viewed without an Autodesk account.

## Related Repositories

| Repository | Description |
|---|---|
| [aps-viewer-api](https://github.com/unnikrishnannp0371/aps-viewer-api) | This repo — Rails API backend |
| [aps-viewer-web](https://github.com/unnikrishnannp0371/aps-viewer-web) | Angular frontend |
| [aps-viewer-deploy](https://github.com/unnikrishnannp0371/aps-viewer-deploy) | Docker & deployment config |

---

## Tech Stack

| Technology | Version | Purpose |
|---|---|---|
| Ruby | 4.0.2 | Runtime |
| Ruby on Rails | 8.1.3 | API framework |
| PostgreSQL | 16 | Database |
| Puma | 8.0+ | Web server |
| rest-client | latest | APS API communication |
| rack-cors | latest | Cross-origin request handling |
| Docker | latest | Containerization |

---

## Prerequisites

### With Docker (recommended)
- [Docker Desktop](https://www.docker.com/products/docker-desktop)
- Clone all three repos and follow setup in [aps-viewer-deploy](https://github.com/unnikrishnannp0371/aps-viewer-deploy)

### Without Docker
- Ruby 4.0.2
- Bundler
- PostgreSQL 16+
- APS credentials from [aps.autodesk.com](https://aps.autodesk.com/myapps)

---

## Running with Docker (Recommended)

Docker setup is managed from the deploy repository. Follow the setup guide there:

```bash
# Clone all three repos side by side
mkdir aps-viewer && cd aps-viewer
git clone https://github.com/unnikrishnannp0371/aps-viewer-api.git
git clone https://github.com/unnikrishnannp0371/aps-viewer-web.git
git clone https://github.com/unnikrishnannp0371/aps-viewer-deploy.git

# Follow setup instructions in deploy repo
cd aps-viewer-deploy
```

See [aps-viewer-deploy](https://github.com/unnikrishnannp0371/aps-viewer-deploy) for full Docker setup instructions.

---

## Running without Docker

**1. Clone the repo**
```bash
git clone https://github.com/unnikrishnannp0371/aps-viewer-api.git
cd aps-viewer-api
```

**2. Install dependencies**
```bash
bundle install
```

**3. Configure environment variables**
```bash
cp .env.example .env
```

Fill in your values in `.env`:
```bash
APS_CLIENT_ID=your_aps_client_id
APS_CLIENT_SECRET=your_aps_client_secret
APS_SCOPE=data:read data:write data:create bucket:read viewables:read user-profile:read
APS_BASE_URL=https://developer.api.autodesk.com
FRONTEND_URL=http://localhost:4200
DATABASE_URL=postgresql://localhost/aps_viewer_api_development
```

**4. Set up the database**
```bash
rails db:create
rails db:migrate
```

**5. Start the server**
```bash
rails s
```

API runs on `http://localhost:3000`.

---

## Environment Variables

| Variable | Description | Example |
|---|---|---|
| `APS_CLIENT_ID` | Autodesk app client ID | `abc123XYZ` |
| `APS_CLIENT_SECRET` | Autodesk app client secret | `xyz789ABC` |
| `APS_SCOPE` | OAuth permission scopes | `data:read data:write` |
| `APS_BASE_URL` | Autodesk API base URL | `https://developer.api.autodesk.com` |
| `FRONTEND_URL` | Where Angular is running | `http://localhost:4200` |
| `DATABASE_URL` | PostgreSQL connection string | `postgresql://user:pass@host/db` |
| `SECRET_KEY_BASE` | Rails secret key | generate with `rails secret` |
| `RAILS_MASTER_KEY` | Rails credentials key | from `config/master.key` |

> **Never commit your `.env` file** — it contains sensitive secrets.

---

## API Endpoints

| Method | Endpoint | Description | Auth Required |
|---|---|---|---|
| GET | `/health` | Health check | No |
| GET | `/api/v1/auth/login` | Initiate Autodesk OAuth | No |
| GET | `/api/v1/auth/callback` | OAuth callback | No |
| GET | `/api/v1/auth/status` | Check login status | No |
| POST | `/api/v1/auth/logout` | Logout | Yes |
| GET | `/api/v1/hubs` | List all hubs | Yes |
| GET | `/api/v1/hubs/:hub_id/projects` | List projects in hub | Yes |
| GET | `/api/v1/hubs/:hub_id/projects/:project_id/folders` | List top folders | Yes |
| GET | `/api/v1/projects/:project_id/folders/:folder_id/contents` | List folder contents | Yes |
| GET | `/api/v1/projects/:project_id/items/:item_id/versions` | List item versions | Yes |
| POST | `/api/v1/translate` | Trigger model translation | Yes |
| GET | `/api/v1/translate/:urn/status` | Check translation status | Yes |
| POST | `/api/v1/share` | Create share link | Yes |
| GET | `/viewer/:token` | View shared model | No |

---

## APS OAuth Callback URLs

Add these in your [APS app settings](https://aps.autodesk.com/myapps):

| Environment | Callback URL |
|---|---|
| Local (without Docker) | `http://localhost:3000/api/v1/auth/callback` |
| Local (with Docker) | `http://localhost/api/v1/auth/callback` |
| Production | `https://your-domain/api/v1/auth/callback` |

---

## ACC Custom Integration

For users to see their BIM360/ACC hubs, each client's ACC Account Admin must add this app as a Custom Integration:

1. Log in to ACC at https://acc.autodesk.com
2. Go to **Account Admin → Apps & Integrations → Custom Integrations**
3. Click **Add Custom Integration**
4. Enter the APS Client ID
5. Select **BIM360 Account Administration** and **Document Management**
6. Complete the wizard

This is a one-time setup per ACC account. All users and projects under that account become accessible after provisioning.

---

## Project Structure

```
aps-viewer-api/
├── app/
│   ├── controllers/
│   │   └── api/v1/
│   │       ├── auth_controller.rb
│   │       ├── hubs_controller.rb
│   │       ├── projects_controller.rb
│   │       ├── folders_controller.rb
│   │       ├── items_controller.rb
│   │       ├── translations_controller.rb
│   │       ├── shares_controller.rb
│   │       └── viewer_controller.rb
│   └── services/
│       └── aps/
│           └── base.rb
├── config/
│   ├── routes.rb
│   └── database.yml
├── Dockerfile                   ← Production Docker image
├── Dockerfile.dev               ← Development Docker image
└── bin/
    └── docker-entrypoint.sh     ← Runs migrations on container start
```

---

## Running Tests

```bash
# Without Docker
bundle exec rails test

# With Docker
docker compose exec api bundle exec rails test
```

> Unit and integration tests are planned for a future release.