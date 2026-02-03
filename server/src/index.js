import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import jwt from 'jsonwebtoken';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
import { Pool } from 'pg';
import multer from 'multer';
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

const app = express();
app.set('trust proxy', true);
app.use(cors());
app.use(express.json());

const PORT = Number(process.env.PORT ?? 8080);
const JWT_SECRET = process.env.JWT_SECRET || 'devjwtsecret';

// Public base URL for absolute links (uploads). Example: https://api.lunarus.ru
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/$/, '');

const LIVEKIT_URL = process.env.LIVEKIT_URL ?? 'http://localhost:7880';
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY ?? 'devkey';
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET ?? 'devsecret';


// RoomServiceClient needs HTTP(S) base URL (not ws/wss)
const LIVEKIT_HTTP_URL = (LIVEKIT_URL || '').replace(/^wss:/, 'https:').replace(/^ws:/, 'http:').replace(/\/$/, '');
const roomService = new RoomServiceClient(LIVEKIT_HTTP_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

// Postgres
const DATABASE_URL = process.env.DATABASE_URL ?? null;
if (!DATABASE_URL) {
  console.warn('[WARN] DATABASE_URL is not set. Messages will not be persisted.');
}
const pool = DATABASE_URL ? new Pool({ connectionString: DATABASE_URL }) : null;

// Uploads
const UPLOADS_DIR = process.env.UPLOADS_DIR || '/app/uploads';
const UPLOADS_FILES_DIR = path.join(UPLOADS_DIR, 'files');
const UPLOADS_TMP_DIR = path.join(UPLOADS_DIR, 'tmp');
fs.mkdirSync(UPLOADS_FILES_DIR, { recursive: true });
fs.mkdirSync(UPLOADS_TMP_DIR, { recursive: true });

<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
// Multer does NOT create the destination directory automatically.
// If it doesn't exist, uploads will fail with ENOENT.
fs.mkdirSync(UPLOADS_TMP_DIR, { recursive: true });

>>>>>>> 894ea6ff02671f77549563e5b245232d3536327a
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
>>>>>>> 098ef00e1850f5c2ab9940727ff31132e9d30409
const upload = multer({ dest: UPLOADS_TMP_DIR });
app.use('/uploads', express.static(UPLOADS_FILES_DIR));

// --- Auth helpers ---
function signJwt(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d' });
}
function verifyJwt(token) {
  return jwt.verify(token, JWT_SECRET);
}
function authMiddleware(req, res, next) {
  const h = req.headers.authorization || '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  if (!m) return res.status(401).json({ error: 'missing authorization' });

  try {
    req.user = jwt.verify(m[1], JWT_SECRET);
    return next();
  } catch (e) {
    return res.status(401).json({ error: 'invalid authorization' });
  }
}

async function ensureSchema() {
  if (!pool) return;
  await pool.query(`
    CREATE TABLE IF NOT EXISTS messages (
      id BIGSERIAL PRIMARY KEY,
      channel_id TEXT NOT NULL,
      author_id TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '',
      kind TEXT NOT NULL DEFAULT 'text',
      media JSONB,
      ts BIGINT NOT NULL
    );
  `);
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_messages_channel_ts ON messages(channel_id, ts);`);
}

function toClientMessage(row) {
  return {
    id: String(row.id),
    channelId: String(row.channel_id),
    authorId: String(row.author_id),
    content: String(row.content ?? ''),
    kind: String(row.kind ?? 'text'),
    media: row.media ?? null,
    ts: Number(row.ts),
  };
}

function absUrl(relativePath) {
  // relativePath example: /uploads/<file>
  if (!PUBLIC_BASE_URL) return relativePath;
  return `${PUBLIC_BASE_URL}${relativePath}`;
}
function getPublicBaseUrl(req) {
  // Prefer explicit env, else derive from reverse-proxy headers.
  if (PUBLIC_BASE_URL) return PUBLIC_BASE_URL;
  const proto = String(req.headers['x-forwarded-proto'] || req.protocol || 'http').split(',')[0].trim();
  const host = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();
  if (!host) return '';
  return `${proto}://${host}`.replace(/\/$/, '');
}


// --- Routes ---
app.get('/health', (_req, res) => res.json({ ok: true }));

app.post('/auth/login', (req, res) => {
  const { username } = req.body ?? {};
  const user = { id: String(username ?? 'user'), username: String(username ?? 'user') };
  const token = signJwt({ sub: user.id, username: user.username });
  res.json({ token, user });
});

// ------------------------------------------------------------
// Discord-like endpoints (compat layer)
// Many clients expect /channels/:channelId/messages.
// Internally we keep /messages?channelId=... for simplicity.
// ------------------------------------------------------------

// Получить последние сообщения канала (Discord-style)
app.get('/channels/:channelId/messages', authMiddleware, async (req, res) => {
  const channelId = String(req.params.channelId ?? 'general');
  const limitRaw = Number(req.query.limit ?? 50);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(100, limitRaw)) : 50;

  if (!pool) return res.status(500).json({ error: 'db not configured' });

  const r = await pool.query(
    `SELECT id, channel_id, author_id, content, kind, media, ts
       FROM messages
      WHERE channel_id = $1
      ORDER BY ts DESC
      LIMIT $2`,
    [channelId, limit]
  );

  // Return oldest->newest
  const items = r.rows.map(toClientMessage).reverse();
  res.json({ items });
});

// Отправить сообщение (Discord-style)
app.post('/channels/:channelId/messages', authMiddleware, async (req, res) => {
  const channelId = String(req.params.channelId ?? 'general');
  const { content = '', kind = 'text', media = null } = req.body ?? {};

  const k = String(kind || 'text');
  const allowed = new Set(['text', 'image', 'gif']);
  if (!allowed.has(k)) return res.status(400).json({ error: 'bad kind' });

  if (!pool) return res.status(500).json({ error: 'db not configured' });

  const msg = {
    channelId,
    authorId: String(req.user?.sub),
    content: String(content ?? ''),
    kind: k,
    media: media ?? null,
    ts: Date.now(),
  };

  const r = await pool.query(
    `INSERT INTO messages(channel_id, author_id, content, kind, media, ts)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING id, channel_id, author_id, content, kind, media, ts`,
    [msg.channelId, msg.authorId, msg.content, msg.kind, msg.media, msg.ts]
  );

  const item = toClientMessage(r.rows[0]);
  broadcast({ t: 'MESSAGE_CREATE', d: item }, (c) => c.channelId === item.channelId);
  res.json({ ok: true, item });
});

// Получить последние сообщения канала (из Postgres)
app.get('/messages', authMiddleware, async (req, res) => {
  const channelId = String(req.query.channelId ?? 'general');
  const limitRaw = Number(req.query.limit ?? 50);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(100, limitRaw)) : 50;

  if (!pool) return res.status(500).json({ error: 'db not configured' });

  const r = await pool.query(
    `SELECT id, channel_id, author_id, content, kind, media, ts
       FROM messages
      WHERE channel_id = $1
      ORDER BY ts DESC
      LIMIT $2`,
    [channelId, limit]
  );

  // Return oldest->newest
  const items = r.rows.map(toClientMessage).reverse();
  res.json({ items });
});

// Отправить сообщение
app.post('/messages', authMiddleware, async (req, res) => {
  const { channelId = 'general', content = '', kind = 'text', media = null } = req.body ?? {};
  const k = String(kind || 'text');
  const allowed = new Set(['text', 'image', 'gif']);
  if (!allowed.has(k)) return res.status(400).json({ error: 'bad kind' });

  if (!pool) return res.status(500).json({ error: 'db not configured' });

  const msg = {
    channelId: String(channelId),
    authorId: String(req.user?.sub),
    content: String(content ?? ''),
    kind: k,
    media: media ?? null,
    ts: Date.now(),
  };

  const r = await pool.query(
    `INSERT INTO messages(channel_id, author_id, content, kind, media, ts)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING id, channel_id, author_id, content, kind, media, ts`,
    [msg.channelId, msg.authorId, msg.content, msg.kind, msg.media, msg.ts]
  );

  const item = toClientMessage(r.rows[0]);

  // пушим в WS подписчикам
  broadcast({ t: 'MESSAGE_CREATE', d: item }, (c) => c.channelId === item.channelId);

  res.json({ ok: true, item });
});

<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
<<<<<<< HEAD
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
>>>>>>> 098ef00e1850f5c2ab9940727ff31132e9d30409
// Discord-like channel routes (compatible with client expectations)
// GET /channels/:channelId/messages?limit=50
app.get('/channels/:channelId/messages', authMiddleware, async (req, res) => {
  const channelId = String(req.params.channelId);
<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
=======
// --- Compatibility routes ---
// Some tools/clients expect Discord-like paths, e.g.:
//   GET  /channels/:channelId/messages
//   POST /channels/:channelId/messages
// These routes forward to the existing /messages endpoints.
app.get('/channels/:channelId/messages', authMiddleware, async (req, res) => {
  const channelId = String(req.params.channelId ?? 'general');
>>>>>>> 894ea6ff02671f77549563e5b245232d3536327a
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
>>>>>>> 098ef00e1850f5c2ab9940727ff31132e9d30409
  const limitRaw = Number(req.query.limit ?? 50);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(100, limitRaw)) : 50;

  if (!pool) return res.status(500).json({ error: 'db not configured' });

  const r = await pool.query(
    `SELECT id, channel_id, author_id, content, kind, media, ts
       FROM messages
      WHERE channel_id = $1
      ORDER BY ts DESC
      LIMIT $2`,
    [channelId, limit]
  );

  const items = r.rows.map(toClientMessage).reverse();
  res.json({ items });
});

<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
<<<<<<< HEAD
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
>>>>>>> 098ef00e1850f5c2ab9940727ff31132e9d30409
// POST /channels/:channelId/messages
app.post('/channels/:channelId/messages', authMiddleware, async (req, res) => {
  const channelId = String(req.params.channelId);
  const { content = '', kind = 'text', media = null } = req.body ?? {};
  const k = String(kind || 'text');
  const allowed = new Set(['text', 'image', 'gif']);
  if (!allowed.has(k)) return res.status(400).json({ error: 'bad kind' });

<<<<<<< HEAD
=======
<<<<<<< HEAD
=======
=======
app.post('/channels/:channelId/messages', authMiddleware, async (req, res) => {
  const channelId = String(req.params.channelId ?? 'general');
  const { content = '', kind = 'text', media = null } = req.body ?? {};

  const k = String(kind || 'text');
  const allowed = new Set(['text', 'image', 'gif']);
  if (!allowed.has(k)) return res.status(400).json({ error: 'bad kind' });
>>>>>>> 894ea6ff02671f77549563e5b245232d3536327a
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
>>>>>>> 098ef00e1850f5c2ab9940727ff31132e9d30409
  if (!pool) return res.status(500).json({ error: 'db not configured' });

  const msg = {
    channelId,
    authorId: String(req.user?.sub),
    content: String(content ?? ''),
    kind: k,
    media: media ?? null,
    ts: Date.now(),
  };

  const r = await pool.query(
    `INSERT INTO messages(channel_id, author_id, content, kind, media, ts)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING id, channel_id, author_id, content, kind, media, ts`,
    [msg.channelId, msg.authorId, msg.content, msg.kind, msg.media, msg.ts]
  );

  const item = toClientMessage(r.rows[0]);
  broadcast({ t: 'MESSAGE_CREATE', d: item }, (c) => c.channelId === item.channelId);

  res.json({ ok: true, item });
});

<<<<<<< HEAD

=======
<<<<<<< HEAD

=======
<<<<<<< HEAD

=======
>>>>>>> 894ea6ff02671f77549563e5b245232d3536327a
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
>>>>>>> 098ef00e1850f5c2ab9940727ff31132e9d30409
// Загрузка изображения (multipart/form-data, поле: file)
app.post('/upload', authMiddleware, upload.single('file'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'missing file' });

  const orig = req.file.originalname || 'file';
  const ext = path.extname(orig).slice(0, 12);
  const id = crypto.randomBytes(16).toString('hex');
  const filename = `${Date.now()}_${id}${ext}`;
  const finalPath = path.join(UPLOADS_FILES_DIR, filename);

  fs.renameSync(req.file.path, finalPath);

  const rel = `/uploads/${filename}`;
  res.json({
    ok: true,
    filename,
    url: absUrl(rel),
    rel,
    mime: req.file.mimetype,
    size: req.file.size,
  });
});

// Tenor GIF search (returns URLs to show in UI)
app.get('/tenor/search', authMiddleware, async (req, res) => {
  const key = process.env.TENOR_API_KEY;
  const clientKey = process.env.TENOR_CLIENT_KEY || 'lunarus';
  if (!key) return res.status(501).json({ error: 'TENOR_API_KEY not configured' });

  const q = String(req.query.q ?? '').trim();
  if (!q) return res.status(400).json({ error: 'missing q' });

  const limitRaw = Number(req.query.limit ?? 16);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(50, limitRaw)) : 16;

  const url = new URL('https://tenor.googleapis.com/v2/search');
  url.searchParams.set('q', q);
  url.searchParams.set('key', key);
  url.searchParams.set('client_key', clientKey);
  url.searchParams.set('limit', String(limit));
  url.searchParams.set('media_filter', 'gif,tinygif');

  const r = await fetch(url.toString());
  if (!r.ok) {
    const t = await r.text();
    return res.status(502).json({ error: 'tenor upstream error', status: r.status, body: t.slice(0, 300) });
  }
  const j = await r.json();

  const results = (j.results || []).map((it) => {
    const mf = it.media_formats || {};
    const tiny = mf.tinygif || mf.gif || null;
    const full = mf.gif || mf.tinygif || null;
    return {
      id: it.id,
      url: full?.url || tiny?.url || null,
      previewUrl: tiny?.url || full?.url || null,
      dims: full?.dims || tiny?.dims || null,
    };
  }).filter(x => x.url);

  res.json({ items: results });
});

// Выдать токен на вход в голосовую комнату (LiveKit)
app.post('/voice/join', authMiddleware, async (req, res) => {
  const room = String(req.body?.room || 'demo-room');

  // LiveKit participants:
  // - identity should be stable (use user id)
  // - name is what UI should display (use username)
  const identity = String(req.user?.sub || req.user?.username || 'user');
  const name = String(req.user?.username || identity);

  const at = new AccessToken(
    process.env.LIVEKIT_API_KEY,
    process.env.LIVEKIT_API_SECRET,
    { identity, name }
  );

  at.addGrant({
    room,
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
  });

  const jwtToken = await at.toJwt();

    // LiveKit clients must connect to a PUBLICLY reachable URL.
  // In docker, LIVEKIT_URL is often set to an internal host (livekit/localhost) which will break clients.
  let url = (process.env.LIVEKIT_PUBLIC_URL || process.env.LIVEKIT_URL || '').toString().replace(/\/$/, '');
  const derived = getPublicBaseUrl(req);
  const looksInternal = /(^|\/\/)(localhost|127\.0\.0\.1|livekit)(:|\/|$)/i.test(url);
  if (!url || looksInternal) {
    // LiveKit is reverse-proxied by Caddy under the SAME domain (see Caddyfile /rtc* /twirp*).
    url = derived || PUBLIC_BASE_URL || url;
  }

  res.json({
    url,
    token: jwtToken,
    room,
  });
});


// List participants currently connected to a LiveKit room. Used to render "who is in voice" under the channel list.
app.get('/voice/rooms/:room/participants', authMiddleware, async (req, res) => {
  try {
    const room = String(req.params.room || '');
    if (!room) return res.status(400).json({ error: 'missing room' });

    const parts = await roomService.listParticipants(room);
    return res.json({
      items: parts.map((p) => ({
        identity: p.identity,
        name: p.name || p.identity,
      })),
    });
  } catch (e) {
    console.error('voice participants error', e);
    return res.status(500).json({ error: 'voice participants failed' });
  }
});

// --- WebSocket Gateway ---
const httpServer = createServer(app);
const wss = new WebSocketServer({ server: httpServer, path: '/gateway' });

// clients: { ws, userId, username, channelId }
const clients = new Set();

const WS_OPEN = 1; // WebSocket.OPEN
function safeSend(ws, obj) {
<<<<<<< HEAD
  if (ws.readyState === WS_OPEN) ws.send(JSON.stringify(obj));
=======
<<<<<<< HEAD
  if (ws.readyState === WS_OPEN) ws.send(JSON.stringify(obj));
=======
<<<<<<< HEAD
  if (ws.readyState === WS_OPEN) ws.send(JSON.stringify(obj));
=======
  // In the `ws` library, OPEN is a constant on the WebSocket class, not the instance.
  // Using `ws.OPEN` breaks sends because it is undefined.
  if (ws.readyState === 1 /* WebSocket.OPEN */) {
    try {
      ws.send(JSON.stringify(obj));
    } catch (_) {
      // Ignore transient socket errors.
    }
  }
>>>>>>> 894ea6ff02671f77549563e5b245232d3536327a
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
>>>>>>> 098ef00e1850f5c2ab9940727ff31132e9d30409
}

function broadcast(obj, predicate = () => true) {
  for (const c of clients) {
    if (predicate(c)) safeSend(c.ws, obj);
  }
}

function parseQuery(url) {
  const q = {};
  const idx = url.indexOf('?');
  if (idx < 0) return q;
  const s = url.slice(idx + 1);
  for (const part of s.split('&')) {
    const [k, v] = part.split('=');
    if (!k) continue;
    q[decodeURIComponent(k)] = decodeURIComponent(v ?? '');
  }
  return q;
}

wss.on('connection', (ws, req) => {
  const q = parseQuery(req.url ?? '');
  const token = q.token;
  if (!token) { ws.close(4401, 'missing token'); return; }

  let user;
  try { user = verifyJwt(token); } catch { ws.close(4401, 'bad token'); return; }

  const client = {
    ws,
    userId: String(user.sub),
    username: String(user.username ?? user.sub),
    channelId: String(q.channelId ?? 'general'),
  };
  clients.add(client);

  safeSend(ws, { t: 'READY', d: { user: { id: client.userId, username: client.username } } });

  ws.on('message', (data) => {
    let msg;
    try { msg = JSON.parse(String(data)); } catch { return; }

    // минимальный протокол:
    // { op: "SUBSCRIBE", d: { channelId } }
    // { op: "TYPING", d: { channelId } }
    if (msg?.op === 'SUBSCRIBE') {
      client.channelId = String(msg?.d?.channelId ?? client.channelId);
      safeSend(ws, { t: 'SUBSCRIBED', d: { channelId: client.channelId } });
    } else if (msg?.op === 'TYPING') {
      broadcast(
        { t: 'TYPING_START', d: { channelId: String(msg?.d?.channelId ?? client.channelId), userId: client.userId } },
        (c) => c.channelId === String(msg?.d?.channelId ?? client.channelId) && c.userId !== client.userId
      );
    }
  });

  ws.on('close', () => {
    clients.delete(client);
  });
});

ensureSchema()
  .then(() => {
    httpServer.listen(PORT, () => {
      console.log(`server listening on :${PORT}`);
      console.log(`gateway ws path: /gateway`);
    });
  })
  .catch((e) => {
    console.error('[FATAL] failed to init schema', e);
    process.exit(1);
  });
