import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import jwt from 'jsonwebtoken';
import { AccessToken } from 'livekit-server-sdk';
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

// Multer does NOT create the destination directory automatically.
// If it doesn't exist, uploads will fail with ENOENT.
fs.mkdirSync(UPLOADS_TMP_DIR, { recursive: true });

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

  // Servers (guilds)
  await pool.query(`
    CREATE TABLE IF NOT EXISTS servers (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      icon TEXT,
      owner_id TEXT NOT NULL,
      created_at BIGINT NOT NULL
    );
  `);

  // Membership
  await pool.query(`
    CREATE TABLE IF NOT EXISTS server_members (
      server_id TEXT NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL,
      nickname TEXT,
      joined_at BIGINT NOT NULL,
      PRIMARY KEY(server_id, user_id)
    );
  `);
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_server_members_user ON server_members(user_id);`);

  // Channels
  await pool.query(`
    CREATE TABLE IF NOT EXISTS channels (
      id TEXT PRIMARY KEY,
      server_id TEXT NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'text', -- text | voice | forum
      position INT NOT NULL DEFAULT 0,
      icon TEXT, -- emoji, custom emoji code, or URL
      nsfw BOOLEAN NOT NULL DEFAULT false,
      is_private BOOLEAN NOT NULL DEFAULT false,
      linked_text_channel_id TEXT,
      room TEXT,
      created_at BIGINT NOT NULL
    );
  `);
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_channels_server_pos ON channels(server_id, position);`);
  // Backward-compatible migrations
  await pool.query(`ALTER TABLE channels ADD COLUMN IF NOT EXISTS room TEXT;`);

  // Invites
  await pool.query(`
    CREATE TABLE IF NOT EXISTS invites (
      code TEXT PRIMARY KEY,
      server_id TEXT NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
      channel_id TEXT,
      created_by TEXT NOT NULL,
      created_at BIGINT NOT NULL,
      expires_at BIGINT,
      max_uses INT,
      uses INT NOT NULL DEFAULT 0
    );
  `);
  await pool.query(`CREATE INDEX IF NOT EXISTS idx_invites_server ON invites(server_id);`);

  // Messages
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

  // Seed default server + channels (migration from "single server" world)
  const now = Date.now();
  await pool.query(
    `INSERT INTO servers(id, name, icon, owner_id, created_at)
     VALUES ('lunarus', 'Lunarus', NULL, 'system', $1)
     ON CONFLICT (id) DO NOTHING`,
    [now]
  );

  // Default channels. We keep ids stable because messages.channel_id is TEXT.
  const seedChannels = [
    { id: 'general', name: 'general', type: 'text', position: 10, icon: '#', nsfw: false, is_private: false, linked: null, room: null },
    { id: 'random', name: 'random', type: 'text', position: 20, icon: '#', nsfw: false, is_private: false, linked: null, room: null },
    { id: 'voice-lobby', name: 'Lobby', type: 'voice', position: 30, icon: '🔊', nsfw: false, is_private: false, linked: 'lobby-chat', room: 'lobby' },
    // Text chat that lives inside the voice channel (not necessarily shown in client channel list)
    { id: 'lobby-chat', name: 'lobby-chat', type: 'text', position: 31, icon: '#', nsfw: false, is_private: false, linked: null, room: null },
  ];

  for (const c of seedChannels) {
    await pool.query(
      `INSERT INTO channels(id, server_id, name, type, position, icon, nsfw, is_private, linked_text_channel_id, room, created_at)
       VALUES ($1, 'lunarus', $2, $3, $4, $5, $6, $7, $8, $9, $10)
       ON CONFLICT (id) DO NOTHING`,
      [c.id, c.name, c.type, c.position, c.icon, c.nsfw, c.is_private, c.linked, c.room, now]
    );
  }
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

function genId(prefix = '') {
  // Short-ish stable ids for URLs.
  // Example: s_6f3a... or c_...
  const id = crypto.randomBytes(12).toString('hex');
  return prefix ? `${prefix}_${id}` : id;
}

function genInviteCode() {
  // Human-friendly code (avoid ambiguous chars)
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let out = '';
  for (let i = 0; i < 8; i++) out += alphabet[Math.floor(Math.random() * alphabet.length)];
  return out;
}

async function ensureMember(serverId, userId) {
  const m = await pool.query(`SELECT 1 FROM server_members WHERE server_id=$1 AND user_id=$2`, [serverId, userId]);
  return m.rowCount > 0;
}

async function isOwner(serverId, userId) {
  const r = await pool.query(`SELECT owner_id FROM servers WHERE id=$1`, [serverId]);
  if (r.rowCount === 0) return false;
  return String(r.rows[0].owner_id) === String(userId);
}


// --- Routes ---
app.get('/health', (_req, res) => res.json({ ok: true }));

app.post('/auth/login', async (req, res) => {
  const { username } = req.body ?? {};
  const user = { id: String(username ?? 'user'), username: String(username ?? 'user') };
  const token = signJwt({ sub: user.id, username: user.username });

  // Auto-join default server in the "single server" migration world.
  if (pool) {
    try {
      await pool.query(
        `INSERT INTO server_members(server_id, user_id, nickname, joined_at)
         VALUES ('lunarus', $1, NULL, $2)
         ON CONFLICT (server_id, user_id) DO NOTHING`,
        [user.id, Date.now()]
      );
    } catch (e) {
      console.warn('[WARN] failed to upsert server_members during login', e);
    }
  }

  res.json({ token, user });
});

// ------------------------------------------------------------
// Servers (guilds) + channels
// ------------------------------------------------------------

app.get('/servers', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const userId = String(req.user?.sub);

  // Ensure membership exists for default server.
  await pool.query(
    `INSERT INTO server_members(server_id, user_id, nickname, joined_at)
     VALUES ('lunarus', $1, NULL, $2)
     ON CONFLICT (server_id, user_id) DO NOTHING`,
    [userId, Date.now()]
  );

  const r = await pool.query(
    `SELECT s.id, s.name, s.icon, s.owner_id AS "ownerId", s.created_at AS "createdAt"
       FROM servers s
       JOIN server_members m ON m.server_id = s.id
      WHERE m.user_id = $1
      ORDER BY s.created_at ASC`,
    [userId]
  );
  res.json({ items: r.rows });
});

// Create a new server (guild)
app.post('/servers', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const userId = String(req.user?.sub);
  const { name, icon } = req.body ?? {};
  const serverName = String(name ?? '').trim();
  if (!serverName) return res.status(400).json({ error: 'name required' });

  const now = Date.now();
  const serverId = genId('s');
  const iconStr = (icon === undefined || icon === null) ? '' : String(icon).trim();
  const serverIcon = iconStr.length === 0 ? null : iconStr;

  await pool.query(
    `INSERT INTO servers(id, name, icon, owner_id, created_at) VALUES ($1, $2, $3, $4, $5)`,
    [serverId, serverName, serverIcon, userId, now]
  );

  await pool.query(
    `INSERT INTO server_members(server_id, user_id, nickname, joined_at) VALUES ($1, $2, NULL, $3)`,
    [serverId, userId, now]
  );

  // Seed default channels for the new server.
  const generalId = `${serverId}-general`;
  const randomId = `${serverId}-random`;
  const voiceId = `${serverId}-voice-lobby`;
  const voiceChatId = `${serverId}-lobby-chat`;
  const voiceRoom = `${serverId}-lobby`;

  const channels = [
    { id: generalId, name: 'general', type: 'text', position: 10, icon: '#', nsfw: false, is_private: false, linked: null, room: null },
    { id: randomId, name: 'random', type: 'text', position: 20, icon: '#', nsfw: false, is_private: false, linked: null, room: null },
    { id: voiceId, name: 'Lobby', type: 'voice', position: 30, icon: '🔊', nsfw: false, is_private: false, linked: voiceChatId, room: voiceRoom },
    { id: voiceChatId, name: 'lobby-chat', type: 'text', position: 31, icon: '#', nsfw: false, is_private: false, linked: null, room: null },
  ];
  for (const c of channels) {
    await pool.query(
      `INSERT INTO channels(id, server_id, name, type, position, icon, nsfw, is_private, linked_text_channel_id, room, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
      [c.id, serverId, c.name, c.type, c.position, c.icon, c.nsfw, c.is_private, c.linked, c.room, now]
    );
  }

  res.json({ ok: true, item: { id: serverId, name: serverName, icon: serverIcon, ownerId: userId, createdAt: now } });
});

// Server info
app.get('/servers/:serverId', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const serverId = String(req.params.serverId);
  const userId = String(req.user?.sub);
  if (!(await ensureMember(serverId, userId))) return res.status(403).json({ error: 'not a member' });

  const r = await pool.query(
    `SELECT id, name, icon, owner_id AS "ownerId", created_at AS "createdAt" FROM servers WHERE id=$1`,
    [serverId]
  );
  if (r.rowCount === 0) return res.status(404).json({ error: 'server not found' });
  res.json({ item: r.rows[0] });
});

// Update server settings (owner only)
app.patch('/servers/:serverId', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const serverId = String(req.params.serverId);
  const userId = String(req.user?.sub);
  if (!(await isOwner(serverId, userId))) return res.status(403).json({ error: 'not owner' });

  const { name, icon } = req.body ?? {};
  const r0 = await pool.query(`SELECT * FROM servers WHERE id=$1`, [serverId]);
  if (r0.rowCount === 0) return res.status(404).json({ error: 'server not found' });
  const nextName = (name !== undefined) ? String(name).trim() : String(r0.rows[0].name);
  const nextIcon = (icon !== undefined) ? (icon === null ? null : String(icon).trim()) : r0.rows[0].icon;
  if (!nextName) return res.status(400).json({ error: 'name required' });

  const r = await pool.query(
    `UPDATE servers SET name=$2, icon=$3 WHERE id=$1 RETURNING id, name, icon, owner_id AS "ownerId", created_at AS "createdAt"`,
    [serverId, nextName, nextIcon]
  );
  res.json({ ok: true, item: r.rows[0] });
});

// Delete server (owner only)
app.delete('/servers/:serverId', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const serverId = String(req.params.serverId);
  const userId = String(req.user?.sub);
  if (!(await isOwner(serverId, userId))) return res.status(403).json({ error: 'not owner' });
  await pool.query(`DELETE FROM servers WHERE id=$1`, [serverId]);
  res.json({ ok: true });
});

app.get('/servers/:serverId/channels', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const serverId = String(req.params.serverId);
  const userId = String(req.user?.sub);

  const m = await pool.query(
    `SELECT 1 FROM server_members WHERE server_id = $1 AND user_id = $2`,
    [serverId, userId]
  );
  if (m.rowCount === 0) return res.status(403).json({ error: 'not a member' });

  const r = await pool.query(
    `SELECT id, server_id AS "serverId", name, type, position, icon, nsfw, is_private AS "isPrivate", linked_text_channel_id AS "linkedTextChannelId", room, created_at AS "createdAt"
       FROM channels
      WHERE server_id = $1
      ORDER BY position ASC, created_at ASC`,
    [serverId]
  );
  res.json({ items: r.rows });
});

// Create a channel (owner only for now)
app.post('/servers/:serverId/channels', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const serverId = String(req.params.serverId);
  const userId = String(req.user?.sub);
  if (!(await isOwner(serverId, userId))) return res.status(403).json({ error: 'not owner' });

  const { name, type = 'text', icon = null, nsfw = false, isPrivate = false } = req.body ?? {};
  const n = String(name ?? '').trim();
  if (!n) return res.status(400).json({ error: 'name required' });
  const t = String(type ?? 'text');
  const allowedTypes = new Set(['text', 'voice', 'forum']);
  if (!allowedTypes.has(t)) return res.status(400).json({ error: 'bad type' });

  const now = Date.now();
  const id = genId('c');
  const posR = await pool.query(`SELECT COALESCE(MAX(position), 0) AS m FROM channels WHERE server_id=$1`, [serverId]);
  const nextPos = Number(posR.rows?.[0]?.m ?? 0) + 10;
  const iconStr = (icon === undefined || icon === null) ? null : String(icon).trim();

  // For voice channels create linked text chat
  let linkedTextChannelId = null;
  let room = null;
  if (t === 'voice') {
    linkedTextChannelId = `${id}-chat`;
    room = `${serverId}-${id}`;
  }

  await pool.query(
    `INSERT INTO channels(id, server_id, name, type, position, icon, nsfw, is_private, linked_text_channel_id, room, created_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
    [id, serverId, n, t, nextPos, iconStr, Boolean(nsfw), Boolean(isPrivate), linkedTextChannelId, room, now]
  );

  if (t === 'voice' && linkedTextChannelId) {
    await pool.query(
      `INSERT INTO channels(id, server_id, name, type, position, icon, nsfw, is_private, linked_text_channel_id, room, created_at)
       VALUES ($1,$2,$3,'text',$4,'#',false,false,NULL,NULL,$5)`,
      [linkedTextChannelId, serverId, `${n}-chat`, nextPos + 1, now]
    );
  }

  const r = await pool.query(
    `SELECT id, server_id AS "serverId", name, type, position, icon, nsfw, is_private AS "isPrivate", linked_text_channel_id AS "linkedTextChannelId", room, created_at AS "createdAt"
       FROM channels WHERE id=$1`,
    [id]
  );
  res.json({ ok: true, item: r.rows[0] });
});

// Delete a channel (owner only for now)
app.delete('/channels/:channelId', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const channelId = String(req.params.channelId);
  const userId = String(req.user?.sub);
  const ch = await pool.query(`SELECT * FROM channels WHERE id=$1`, [channelId]);
  if (ch.rowCount === 0) return res.status(404).json({ error: 'channel not found' });
  const serverId = String(ch.rows[0].server_id);
  if (!(await isOwner(serverId, userId))) return res.status(403).json({ error: 'not owner' });

  // If it's voice, also delete linked text channel.
  const linked = ch.rows[0].linked_text_channel_id;
  await pool.query(`DELETE FROM channels WHERE id=$1`, [channelId]);
  if (linked) await pool.query(`DELETE FROM channels WHERE id=$1`, [String(linked)]);
  res.json({ ok: true });
});

// --- Invites ---
app.post('/servers/:serverId/invites', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const serverId = String(req.params.serverId);
  const userId = String(req.user?.sub);
  if (!(await ensureMember(serverId, userId))) return res.status(403).json({ error: 'not a member' });

  const { channelId = null, expiresAt = null, maxUses = null } = req.body ?? {};
  const now = Date.now();
  let code = genInviteCode();
  // Ensure uniqueness
  for (let i = 0; i < 5; i++) {
    const ex = await pool.query(`SELECT 1 FROM invites WHERE code=$1`, [code]);
    if (ex.rowCount === 0) break;
    code = genInviteCode();
  }
  await pool.query(
    `INSERT INTO invites(code, server_id, channel_id, created_by, created_at, expires_at, max_uses, uses)
     VALUES ($1,$2,$3,$4,$5,$6,$7,0)`,
    [code, serverId, channelId ? String(channelId) : null, userId, now, expiresAt ? Number(expiresAt) : null, maxUses ? Number(maxUses) : null]
  );
  res.json({ ok: true, item: { code, serverId, channelId, createdBy: userId, createdAt: now, expiresAt, maxUses, uses: 0 } });
});

// Invite preview
app.get('/invites/:code', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const code = String(req.params.code).trim().toUpperCase();
  const r = await pool.query(
    `SELECT i.code, i.server_id AS "serverId", i.channel_id AS "channelId", i.expires_at AS "expiresAt", i.max_uses AS "maxUses", i.uses,
            s.name AS "serverName", s.icon AS "serverIcon"
       FROM invites i JOIN servers s ON s.id = i.server_id
      WHERE i.code=$1`,
    [code]
  );
  if (r.rowCount === 0) return res.status(404).json({ error: 'invite not found' });
  const inv = r.rows[0];
  if (inv.expiresAt && Number(inv.expiresAt) < Date.now()) return res.status(410).json({ error: 'invite expired' });
  if (inv.maxUses && Number(inv.uses) >= Number(inv.maxUses)) return res.status(410).json({ error: 'invite max uses reached' });
  res.json({ item: inv });
});

// Join by invite
app.post('/invites/:code/join', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const code = String(req.params.code).trim().toUpperCase();
  const userId = String(req.user?.sub);

  const r = await pool.query(`SELECT * FROM invites WHERE code=$1`, [code]);
  if (r.rowCount === 0) return res.status(404).json({ error: 'invite not found' });
  const inv = r.rows[0];
  if (inv.expires_at && Number(inv.expires_at) < Date.now()) return res.status(410).json({ error: 'invite expired' });
  if (inv.max_uses && Number(inv.uses) >= Number(inv.max_uses)) return res.status(410).json({ error: 'invite max uses reached' });

  const serverId = String(inv.server_id);
  await pool.query(
    `INSERT INTO server_members(server_id, user_id, nickname, joined_at)
     VALUES ($1,$2,NULL,$3)
     ON CONFLICT (server_id, user_id) DO NOTHING`,
    [serverId, userId, Date.now()]
  );
  await pool.query(`UPDATE invites SET uses = uses + 1 WHERE code=$1`, [code]);

  const srv = await pool.query(`SELECT id, name, icon, owner_id AS "ownerId", created_at AS "createdAt" FROM servers WHERE id=$1`, [serverId]);
  res.json({ ok: true, item: srv.rows[0] });
});

// Update channel metadata (icon, flags, name, type)
app.patch('/channels/:channelId', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const channelId = String(req.params.channelId);
  const userId = String(req.user?.sub);

  const ch = await pool.query(`SELECT * FROM channels WHERE id = $1`, [channelId]);
  if (ch.rowCount === 0) return res.status(404).json({ error: 'channel not found' });

  const serverId = String(ch.rows[0].server_id);
  const isMember = await pool.query(`SELECT 1 FROM server_members WHERE server_id=$1 AND user_id=$2`, [serverId, userId]);
  if (isMember.rowCount === 0) return res.status(403).json({ error: 'not a member' });

  // For now, allow any member to edit metadata. Later: roles/permissions.
  const { name, icon, nsfw, isPrivate, type, position, linkedTextChannelId, room } = req.body ?? {};

  const nextName = (name !== undefined) ? String(name) : String(ch.rows[0].name);
  const nextIcon = (icon !== undefined) ? (icon === null ? null : String(icon)) : ch.rows[0].icon;
  const nextNsfw = (nsfw !== undefined) ? Boolean(nsfw) : Boolean(ch.rows[0].nsfw);
  const nextPrivate = (isPrivate !== undefined) ? Boolean(isPrivate) : Boolean(ch.rows[0].is_private);
  const nextType = (type !== undefined) ? String(type) : String(ch.rows[0].type);
  const nextPos = (position !== undefined && Number.isFinite(Number(position))) ? Number(position) : Number(ch.rows[0].position ?? 0);
  const nextLinked = (linkedTextChannelId !== undefined) ? (linkedTextChannelId === null ? null : String(linkedTextChannelId)) : ch.rows[0].linked_text_channel_id;
  const nextRoom = (room !== undefined) ? (room === null ? null : String(room)) : ch.rows[0].room;

  const allowedTypes = new Set(['text', 'voice', 'forum']);
  if (!allowedTypes.has(nextType)) return res.status(400).json({ error: 'bad type' });

  const r = await pool.query(
    `UPDATE channels
        SET name=$2, icon=$3, nsfw=$4, is_private=$5, type=$6, position=$7, linked_text_channel_id=$8, room=$9
      WHERE id=$1
    RETURNING id, server_id AS "serverId", name, type, position, icon, nsfw, is_private AS "isPrivate", linked_text_channel_id AS "linkedTextChannelId", room, created_at AS "createdAt"`,
    [channelId, nextName, nextIcon, nextNsfw, nextPrivate, nextType, nextPos, nextLinked, nextRoom]
  );

  res.json({ ok: true, item: r.rows[0] });
});

// Delete channel (owner only). If it's a voice channel, also delete its linked chat.
app.delete('/channels/:channelId', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const channelId = String(req.params.channelId);
  const userId = String(req.user?.sub);

  const ch = await pool.query(`SELECT * FROM channels WHERE id=$1`, [channelId]);
  if (ch.rowCount === 0) return res.status(404).json({ error: 'channel not found' });
  const serverId = String(ch.rows[0].server_id);
  if (!(await isOwner(serverId, userId))) return res.status(403).json({ error: 'not owner' });

  const linked = ch.rows[0].linked_text_channel_id ? String(ch.rows[0].linked_text_channel_id) : null;
  await pool.query(`DELETE FROM channels WHERE id=$1`, [channelId]);
  if (linked) {
    await pool.query(`DELETE FROM channels WHERE id=$1 AND server_id=$2`, [linked, serverId]);
  }
  res.json({ ok: true });
});

// ------------------------------------------------------------
// Invites
// ------------------------------------------------------------

// Create invite (owner only for now)
app.post('/servers/:serverId/invites', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const serverId = String(req.params.serverId);
  const userId = String(req.user?.sub);
  if (!(await isOwner(serverId, userId))) return res.status(403).json({ error: 'not owner' });

  const { channelId = null, expiresAt = null, maxUses = null } = req.body ?? {};
  const code = genInviteCode();
  const now = Date.now();

  await pool.query(
    `INSERT INTO invites(code, server_id, channel_id, created_by, created_at, expires_at, max_uses, uses)
     VALUES ($1,$2,$3,$4,$5,$6,$7,0)`,
    [code, serverId, channelId ? String(channelId) : null, userId, now, expiresAt ? Number(expiresAt) : null, maxUses ? Number(maxUses) : null]
  );

  res.json({ ok: true, item: { code, serverId, channelId, createdBy: userId, createdAt: now, expiresAt, maxUses, uses: 0 } });
});

// Invite preview
app.get('/invites/:code', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const code = String(req.params.code).trim();
  const r = await pool.query(
    `SELECT i.code, i.server_id AS "serverId", i.channel_id AS "channelId", i.expires_at AS "expiresAt", i.max_uses AS "maxUses", i.uses,
            s.name AS "serverName", s.icon AS "serverIcon"
       FROM invites i
       JOIN servers s ON s.id=i.server_id
      WHERE i.code=$1`,
    [code]
  );
  if (r.rowCount === 0) return res.status(404).json({ error: 'invite not found' });
  const it = r.rows[0];
  const now = Date.now();
  if (it.expiresAt && Number(it.expiresAt) < now) return res.status(410).json({ error: 'invite expired' });
  if (it.maxUses && Number(it.uses) >= Number(it.maxUses)) return res.status(410).json({ error: 'invite max uses reached' });
  res.json({ item: it });
});

// Join server by invite
app.post('/invites/:code/join', authMiddleware, async (req, res) => {
  if (!pool) return res.status(500).json({ error: 'db not configured' });
  const code = String(req.params.code).trim();
  const userId = String(req.user?.sub);
  const r = await pool.query(`SELECT * FROM invites WHERE code=$1`, [code]);
  if (r.rowCount === 0) return res.status(404).json({ error: 'invite not found' });
  const inv = r.rows[0];
  const now = Date.now();
  if (inv.expires_at && Number(inv.expires_at) < now) return res.status(410).json({ error: 'invite expired' });
  if (inv.max_uses && Number(inv.uses) >= Number(inv.max_uses)) return res.status(410).json({ error: 'invite max uses reached' });

  const serverId = String(inv.server_id);
  await pool.query(
    `INSERT INTO server_members(server_id, user_id, nickname, joined_at)
     VALUES ($1,$2,NULL,$3)
     ON CONFLICT (server_id, user_id) DO NOTHING`,
    [serverId, userId, now]
  );
  await pool.query(`UPDATE invites SET uses=uses+1 WHERE code=$1`, [code]);

  const srv = await pool.query(`SELECT id, name, icon, owner_id AS "ownerId", created_at AS "createdAt" FROM servers WHERE id=$1`, [serverId]);
  res.json({ ok: true, item: srv.rows[0] });
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
  const room = req.body?.room || 'demo-room';

  const identity =
    req.user?.username ||
    req.user?.sub ||
    'user';

  const at = new AccessToken(
    process.env.LIVEKIT_API_KEY,
    process.env.LIVEKIT_API_SECRET,
    { identity }
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

// --- WebSocket Gateway ---
const httpServer = createServer(app);
const wss = new WebSocketServer({ server: httpServer, path: '/gateway' });

// clients: { ws, userId, username, channelId }
const clients = new Set();

function safeSend(ws, obj) {
  // In the `ws` library, OPEN is a constant on the WebSocket class, not the instance.
  // Using `ws.OPEN` breaks sends because it is undefined.
  if (ws.readyState === 1 /* WebSocket.OPEN */) {
    try {
      ws.send(JSON.stringify(obj));
    } catch (_) {
      // Ignore transient socket errors.
    }
  }
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
