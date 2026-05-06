# APS Viewer API

A Ruby on Rails API backend for the APS Viewer application. Handles Autodesk Platform Services (APS) authentication, session management, and data access for browsing ACC hubs, projects, folders and files. Generates shareable links for 3D models that can be viewed without an Autodesk account.

---

## Tech Stack

| Technology | Version | Purpose |
|------------|---------|---------|
| Ruby | 4.0.2 | Runtime |
| Ruby on Rails | 8.1.3 | API framework |
| PostgreSQL | 9.5+ | Database |
| Puma | 5.0+ | Web server |
| rest-client | latest | APS API communication |
| rack-cors | latest | Cross-origin request handling |
| Kamal | latest | Deployment |

---
## Prerequisites

- Ruby 4.0.2
- Bundler
- PostgreSQL 9.5+
- An Autodesk Platform Services (APS) application with:
  - Client ID
  - Client Secret
  - Callback URL configured
  - All regions enabled (US, EMEA, AUS, IND, GBR, CAN, DEU, JPN)
---

## Local Setup

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

Copy the sample environment file:

```bash
cp .env.sample .env
```

Then update the values in `.env`:
```
APS_CLIENT_ID=your_aps_client_id
APS_CLIENT_SECRET=your_aps_client_secret
APS_SCOPE=data:read data:write data:create bucket:read viewables:read user-profile:read
APS_BASE_URL=https://developer.api.autodesk.com
FRONTEND_URL=http://localhost:4200
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

Rails runs on `http://localhost:3000` by default.

---

## Environment Variables

A `.env.example` file is included in the repository with all required variables.

  - Copy it to `.env` and fill in your actual credentials.
  - **Do NOT commit your** `.env` **file** - it contains sensitive secrets.

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

## Running Tests

```bash
rails test
```

> Unit and integration tests are planned for a future release.

---

## Related Repositories

- **Frontend:** [aps-viewer-web](https://github.com/unnikrishnannp0371/aps-viewer-web) — Angular frontend
---