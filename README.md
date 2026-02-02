# Lunarus — a basic self-host template (Flutter Desktop + LiveKit)

This is an MVP skeleton "like Discord": text chat (HTTP + WebSocket) + voice rooms via LiveKit (SFU).
It's designed so that it can be set up locally and then transferred to a VDS/VPS.

## What's inside
- `server/` — Node.js backend (REST + WS Gateway + LiveKit token issuance)
- `client_flutter/` — Flutter desktop client (chat + voice, dark theme)
- `infra/` — LiveKit/coturn configs + Caddyfile
- `docker-compose.yml` — local development
- `docker-compose.vds.yml` — example for VDS (Caddy + TLS + minimal external ports)

---

## Local run (for development)
1) Copy env:
```bash
cp server/.env.example server/.env
```

2) Run:
```bash
docker compose up -d --build
```

3) Run the client:
```bash
cd client_flutter
flutter pub get
flutter run -d linux # or windows
```

By default, the client waits for `http://localhost:8080`.

---

## Message Storage (Postgres)
Messages are stored in Postgres (the `messages` table is created automatically when the `server` starts).

API:
- `GET /messages?channelId=general` (requires `Authorization: Bearer <token>`)
- `POST /messages` body: `{ channelId, content, kind, media }`
- `kind`: `text | image | gif`
- `media`: object (e.g. `{ "url": "https://..." }`)

---

## Images
File upload to the backend:
- `POST /upload` (multipart/form-data, `file` field) → returns a URL
- Files are stored in `./uploads` (volume), served via `/uploads/...`

The client currently has the simplest UX:
- you can send a **URL**
- or specify a **local path** to the file, the client will upload it to the server and send it via message

---

## GIF via Tenor
The backend proxies Tenor search:
- `GET /tenor/search?q=...`

You need to specify in `server/.env`:
- `TENOR_API_KEY=...`
- `TENOR_CLIENT_KEY=lunarus` (can be left as is)

If the key is not specified, the client will display an error when searching for GIFs.

---

## Launching on a VDS (Ubuntu 22.04 / domain api.lunarus.ru)
1) DNS:
- A-record `api.lunarus.ru` → your VDS IP

2) Open ports on the server/firewall:
- `80/tcp`, `443/tcp` (Caddy/TLS)
- `7881/tcp` (LiveKit ICE-TCP fallback)
- `61000-61999/udp` (LiveKit media)
- `3478/udp` and `5349/tcp` (TURN; can be disabled, but then voice may not work for some users)

3) Configure `server/.env`:
- `PUBLIC_BASE_URL=https://api.lunarus.ru`
- `LIVEKIT_URL=wss://api.lunarus.ru`
- `JWT_SECRET=...` (change!)
- `LIVEKIT_API_SECRET=...` (minimum 32 characters)
- `TENOR_API_KEY=...` (optional)

4) Boot the stack:
```bash
docker compose -f docker-compose.vds.yml up -d --build
```

Caddy will automatically issue a TLS certificate via Let's Encrypt.

---

## Notes
- Currently, `channelId` is just a string (e.g. `general`). "Servers/channels/permissions" can be added later in separate tables.
- For stable voice "from any network," a valid TURN (coturn) and an open LiveKit UDP range are almost always required.