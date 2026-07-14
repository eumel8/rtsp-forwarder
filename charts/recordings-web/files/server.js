// Recordings Web UI
// Serves a directory of MP4 segments per camera with HTML5 player,
// metadata via ffprobe, thumbnails, delete, and YouTube upload.
//
// Env:
//   RECORDINGS_DIR   default /recordings
//   CAMERAS          comma-separated list (e.g. "cam01,cam02"); auto-detect if unset
//   PORT             default 3000
//   ALLOW_DELETE     "true" (default) | "false"
//   THUMB_DIR        default /tmp/thumbs
//   TITLE            default "Recordings"
//   YOUTUBE_CLIENT_ID       OAuth2 client ID (GIS popup flow)
//   YOUTUBE_CLIENT_SECRET   OAuth2 client secret
//   YOUTUBE_DATA_DIR        writable dir for token storage (default /data)

import express from 'express';
import { promises as fs, createReadStream, existsSync, statSync } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { google } from 'googleapis';
import crypto from 'node:crypto';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const RECORDINGS_DIR = process.env.RECORDINGS_DIR || '/recordings';
const CAMERAS_ENV = process.env.CAMERAS || '';
const PORT = parseInt(process.env.PORT || '3000', 10);
const ALLOW_DELETE = (process.env.ALLOW_DELETE || 'true').toLowerCase() === 'true';
const THUMB_DIR = process.env.THUMB_DIR || '/tmp/thumbs';
const TITLE = process.env.TITLE || 'Recordings';

// YouTube OAuth2 configuration (GIS popup flow)
const YT_CLIENT_ID = process.env.YOUTUBE_CLIENT_ID || '';
const YT_CLIENT_SECRET = process.env.YOUTUBE_CLIENT_SECRET || '';
const YT_DATA_DIR = process.env.YOUTUBE_DATA_DIR || '/data';
const YT_DATA_FILE = path.join(YT_DATA_DIR, 'youtube.json');
const YT_CONFIGURED = Boolean(YT_CLIENT_ID && YT_CLIENT_SECRET);

// In-memory upload jobs: { id, state, progress, videoId, videoUrl, error }
const uploadJobs = new Map();

await fs.mkdir(THUMB_DIR, { recursive: true });

const app = express();
app.set('view engine', 'pug');
app.set('views', path.join(__dirname, 'views'));
app.use(express.json());

// ---------- helpers ----------

async function listCameras() {
  if (CAMERAS_ENV.trim()) {
    return CAMERAS_ENV.split(',').map((s) => s.trim()).filter(Boolean);
  }
  try {
    const entries = await fs.readdir(RECORDINGS_DIR, { withFileTypes: true });
    return entries.filter((e) => e.isDirectory()).map((e) => e.name).sort();
  } catch {
    return [];
  }
}

function safeCam(cam) {
  return /^[a-zA-Z0-9_-]+$/.test(cam);
}

function safeFile(file) {
  return /^[a-zA-Z0-9_.-]+\.mp4$/.test(file);
}

async function listFiles(cam) {
  const base = path.join(RECORDINGS_DIR, cam);
  // Some recorder setups create a redundant <cam>/<cam>/ subfolder; prefer it
  // when present so we don't list an empty directory. Falls back to the base
  // dir for the clean layout.
  let dir = base;
  try {
    const nested = path.join(base, cam);
    const st = await fs.stat(nested);
    if (st.isDirectory()) {
      const inner = await fs.readdir(nested);
      if (inner.some((n) => n.endsWith('.mp4'))) dir = nested;
    }
  } catch {
    /* no nested dir */
  }
  try {
    const names = await fs.readdir(dir);
    const files = await Promise.all(
      names
        .filter((n) => n.endsWith('.mp4'))
        .map(async (name) => {
          const full = path.join(dir, name);
          const st = await fs.stat(full);
          return {
            name,
            size: st.size,
            mtime: st.mtime,
            _dir: dir,
          };
        }),
    );
    files.sort((a, b) => b.mtime - a.mtime); // neueste zuerst
    return files;
  } catch {
    return [];
  }
}

// resolve absolute path of a recording file, honouring nested layout
async function resolveFile(cam, file) {
  const candidates = [
    path.join(RECORDINGS_DIR, cam, file),
    path.join(RECORDINGS_DIR, cam, cam, file),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return null;
}

function ffprobe(filePath) {
  return new Promise((resolve) => {
    const p = spawn('ffprobe', [
      '-v', 'error',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      filePath,
    ]);
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => {
      if (code !== 0) return resolve({ error: err.trim() || `exit ${code}` });
      try {
        resolve(JSON.parse(out));
      } catch (e) {
        resolve({ error: 'parse failed' });
      }
    });
  });
}

async function videoInfo(filePath) {
  const probe = await ffprobe(filePath);
  if (probe.error) return { error: probe.error };
  const v = (probe.streams || []).find((s) => s.codec_type === 'video') || {};
  const a = (probe.streams || []).find((s) => s.codec_type === 'audio') || {};
  const fmt = probe.format || {};
  const fps =
    v.avg_frame_rate && v.avg_frame_rate !== '0/0'
      ? (() => {
          const [n, d] = v.avg_frame_rate.split('/').map(Number);
          return d ? +(n / d).toFixed(2) : null;
        })()
      : null;
  return {
    duration: fmt.duration ? parseFloat(fmt.duration) : null,
    bitrate: fmt.bit_rate ? parseInt(fmt.bit_rate, 10) : null,
    size: fmt.size ? parseInt(fmt.size, 10) : null,
    video: {
      codec: v.codec_name,
      profile: v.profile,
      width: v.width,
      height: v.height,
      fps,
      pix_fmt: v.pix_fmt,
    },
    audio: a.codec_name
      ? {
          codec: a.codec_name,
          channels: a.channels,
          sample_rate: a.sample_rate ? parseInt(a.sample_rate, 10) : null,
        }
      : null,
  };
}

function thumbnailPath(cam, file) {
  return path.join(THUMB_DIR, `${cam}__${file}.jpg`);
}

function generateThumbnail(srcPath, dstPath) {
  return new Promise((resolve, reject) => {
    const p = spawn('ffmpeg', [
      '-y',
      '-ss', '00:00:02',
      '-i', srcPath,
      '-frames:v', '1',
      '-vf', 'scale=320:-1',
      '-q:v', '5',
      dstPath,
    ]);
    let err = '';
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => {
      code === 0 ? resolve() : reject(new Error(err.trim() || `ffmpeg exit ${code}`));
    });
  });
}

function fmtSize(bytes) {
  if (!bytes && bytes !== 0) return '?';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0,
    n = bytes;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n.toFixed(n >= 100 ? 0 : 1)} ${u[i]}`;
}

function fmtDuration(sec) {
  if (sec == null) return '?';
  sec = Math.round(sec);
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  return h > 0
    ? `${h}h ${String(m).padStart(2, '0')}m ${String(s).padStart(2, '0')}s`
    : `${m}m ${String(s).padStart(2, '0')}s`;
}

app.locals.fmtSize = fmtSize;
app.locals.fmtDuration = fmtDuration;
app.locals.title = TITLE;
app.locals.allowDelete = ALLOW_DELETE;
app.locals.ytClientId = YT_CLIENT_ID;
app.locals.ytConfigured = YT_CONFIGURED;

// Dynamic: check YouTube connection status on each request
app.use(async (_req, res, next) => {
  res.locals.ytConnected = YT_CONFIGURED ? await isYtConnected() : false;
  next();
});

// ---------- YouTube helpers ----------

async function readYtToken() {
  try {
    const raw = await fs.readFile(YT_DATA_FILE, 'utf8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function writeYtToken(data) {
  await fs.mkdir(YT_DATA_DIR, { recursive: true });
  await fs.writeFile(YT_DATA_FILE, JSON.stringify(data, null, 2));
}

async function deleteYtToken() {
  try { await fs.unlink(YT_DATA_FILE); } catch { /* ignore */ }
}

async function isYtConnected() {
  const token = await readYtToken();
  return Boolean(token?.refresh_token);
}

function getOAuth2Client() {
  return new google.auth.OAuth2(YT_CLIENT_ID, YT_CLIENT_SECRET);
}

async function getYouTubeClient() {
  const token = await readYtToken();
  if (!token?.refresh_token) throw new Error('YouTube not connected');
  const oauth2 = getOAuth2Client();
  oauth2.setCredentials({ refresh_token: token.refresh_token });
  return google.youtube({ version: 'v3', auth: oauth2 });
}

function startYouTubeUpload(filePath, metadata) {
  const id = crypto.randomUUID();
  const job = { id, state: 'starting', progress: 0, videoId: null, videoUrl: null, error: null };
  uploadJobs.set(id, job);

  (async () => {
    try {
      const youtube = await getYouTubeClient();
      const fileSize = (await fs.stat(filePath)).size;

      const res = await youtube.videos.insert({
        part: ['snippet', 'status'],
        requestBody: {
          snippet: {
            title: metadata.title || path.basename(filePath),
            description: metadata.description || '',
          },
          status: {
            privacyStatus: metadata.privacy || 'private',
            selfDeclaredMadeForKids: false,
          },
        },
        media: {
          body: createReadStream(filePath),
        },
      }, {
        onUploadProgress: (evt) => {
          job.progress = Math.round((evt.bytesRead / fileSize) * 100);
          job.state = 'uploading';
        },
      });

      job.state = 'done';
      job.progress = 100;
      job.videoId = res.data.id;
      job.videoUrl = `https://www.youtube.com/watch?v=${res.data.id}`;
    } catch (e) {
      job.state = 'error';
      job.error = e.message || String(e);
      console.error('YouTube upload failed:', job.error);
    }
  })();

  return id;
}

// ---------- routes ----------

app.get('/healthz', (_req, res) => res.send('ok'));

app.get('/legal', (_req, res) => {
  res.render('legal');
});

app.get('/', async (_req, res) => {
  const cams = await listCameras();
  const summary = await Promise.all(
    cams.map(async (cam) => {
      const files = await listFiles(cam);
      const total = files.reduce((s, f) => s + f.size, 0);
      return {
        name: cam,
        count: files.length,
        size: total,
        latest: files[0]?.mtime || null,
      };
    }),
  );
  res.render('index', { cameras: summary });
});

app.get('/cam/:cam', async (req, res) => {
  const { cam } = req.params;
  if (!safeCam(cam)) return res.status(400).send('invalid camera name');
  const files = await listFiles(cam);
  res.render('camera', { cam, files });
});

app.get('/cam/:cam/:file/info', async (req, res) => {
  const { cam, file } = req.params;
  if (!safeCam(cam) || !safeFile(file)) return res.status(400).json({ error: 'bad name' });
  const full = await resolveFile(cam, file);
  if (!full) return res.status(404).json({ error: 'not found' });
  res.json(await videoInfo(full));
});

app.get('/cam/:cam/:file/thumbnail', async (req, res) => {
  const { cam, file } = req.params;
  if (!safeCam(cam) || !safeFile(file)) return res.status(400).end();
  const src = await resolveFile(cam, file);
  if (!src) return res.status(404).end();
  const dst = thumbnailPath(cam, file);
  if (!existsSync(dst)) {
    try {
      await generateThumbnail(src, dst);
    } catch (e) {
      console.warn('thumbnail failed for', cam, file, e.message);
      return res.status(204).end();
    }
  }
  res.sendFile(dst);
});

app.get('/cam/:cam/:file/play', (req, res) => {
  const { cam, file } = req.params;
  if (!safeCam(cam) || !safeFile(file)) return res.status(400).send('bad name');
  res.render('play', { cam, file });
});

// Range-Request fähiger Streamer
app.get('/cam/:cam/:file/stream', async (req, res) => {
  const { cam, file } = req.params;
  if (!safeCam(cam) || !safeFile(file)) return res.status(400).end();
  const full = await resolveFile(cam, file);
  if (!full) return res.status(404).end();

  const st = statSync(full);
  const total = st.size;
  const range = req.headers.range;
  if (!range) {
    res.writeHead(200, {
      'Content-Length': total,
      'Content-Type': 'video/mp4',
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-cache',
    });
    return createReadStream(full).pipe(res);
  }
  const m = /bytes=(\d*)-(\d*)/.exec(range);
  const start = m && m[1] ? parseInt(m[1], 10) : 0;
  const end = m && m[2] ? parseInt(m[2], 10) : total - 1;
  if (start >= total || end >= total) {
    res.writeHead(416, { 'Content-Range': `bytes */${total}` });
    return res.end();
  }
  res.writeHead(206, {
    'Content-Range': `bytes ${start}-${end}/${total}`,
    'Accept-Ranges': 'bytes',
    'Content-Length': end - start + 1,
    'Content-Type': 'video/mp4',
    'Cache-Control': 'no-cache',
  });
  createReadStream(full, { start, end }).pipe(res);
});

app.get('/cam/:cam/:file/download', async (req, res) => {
  const { cam, file } = req.params;
  if (!safeCam(cam) || !safeFile(file)) return res.status(400).end();
  const full = await resolveFile(cam, file);
  if (!full) return res.status(404).end();
  res.download(full, file);
});

app.delete('/cam/:cam/:file', async (req, res) => {
  if (!ALLOW_DELETE) return res.status(403).json({ error: 'delete disabled' });
  const { cam, file } = req.params;
  if (!safeCam(cam) || !safeFile(file)) return res.status(400).json({ error: 'bad name' });
  const full = await resolveFile(cam, file);
  if (!full) return res.status(404).json({ error: 'not found' });
  try {
    await fs.unlink(full);
    // Thumbnail-Cache mit weg
    const tn = thumbnailPath(cam, file);
    if (existsSync(tn)) await fs.unlink(tn);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ---------- YouTube OAuth (GIS popup flow) ----------

app.get('/connect/youtube', async (_req, res) => {
  if (!YT_CLIENT_ID || !YT_CLIENT_SECRET) {
    return res.status(500).send('YouTube not configured: missing YOUTUBE_CLIENT_ID / YOUTUBE_CLIENT_SECRET');
  }
  const connected = await isYtConnected();
  let channelName = null;
  if (connected) {
    try {
      const youtube = await getYouTubeClient();
      const r = await youtube.channels.list({ part: ['snippet'], mine: true });
      channelName = r.data.items?.[0]?.snippet?.title || null;
    } catch { /* ignore */ }
  }
  res.render('connect-youtube', { connected, channelName });
});

app.post('/api/youtube/connect', async (req, res) => {
  if (!YT_CLIENT_ID || !YT_CLIENT_SECRET) {
    return res.status(400).json({ error: 'YouTube not configured' });
  }
  const { code } = req.body || {};
  if (!code) return res.status(400).json({ error: 'Missing code' });
  try {
    // Direct token exchange — redirect_uri must be "postmessage" for GIS popup flow
    const params = new URLSearchParams({
      code,
      client_id: YT_CLIENT_ID,
      client_secret: YT_CLIENT_SECRET,
      grant_type: 'authorization_code',
      redirect_uri: 'postmessage',
    });
    const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
    });
    const tokenData = await tokenRes.json();
    console.log('Google token response:', JSON.stringify(tokenData));
    if (!tokenRes.ok || !tokenData.access_token) {
      return res.status(400).json({ error: 'Token exchange failed: ' + (tokenData.error_description || tokenData.error || JSON.stringify(tokenData)) });
    }
    if (!tokenData.refresh_token) {
      return res.status(400).json({ error: 'No refresh token received. Try again with a different Google account or revoke access first at myaccount.google.com/permissions.' });
    }
    // Fetch channel name
    let channelName = null;
    try {
      const oauth2 = getOAuth2Client();
      oauth2.setCredentials({ access_token: tokenData.access_token });
      const youtube = google.youtube({ version: 'v3', auth: oauth2 });
      const r = await youtube.channels.list({ part: ['snippet'], mine: true });
      channelName = r.data.items?.[0]?.snippet?.title || null;
    } catch { /* ignore */ }
    await writeYtToken({ refresh_token: tokenData.refresh_token, channel_name: channelName });
    res.json({ ok: true, channelName });
  } catch (e) {
    res.status(500).json({ error: 'Token exchange failed: ' + e.message });
  }
});

app.post('/api/youtube/disconnect', async (_req, res) => {
  await deleteYtToken();
  res.json({ ok: true });
});

// ---------- YouTube API ----------

app.get('/api/youtube/status', async (_req, res) => {
  const connected = await isYtConnected();
  let channelName = null;
  if (connected) {
    try {
      const youtube = await getYouTubeClient();
      const r = await youtube.channels.list({ part: ['snippet'], mine: true });
      channelName = r.data.items?.[0]?.snippet?.title || null;
    } catch { /* ignore */ }
  }
  res.json({ configured: YT_CONFIGURED, connected, channelName });
});

app.post('/api/youtube/upload', express.json(), async (req, res) => {
  if (!YT_CONFIGURED) return res.status(400).json({ error: 'YouTube not configured (missing client ID/secret)' });
  if (!(await isYtConnected())) return res.status(400).json({ error: 'YouTube not connected. Visit /connect/youtube to connect.' });
  const { cam, file, title, description, privacy } = req.body || {};
  if (!cam || !file) return res.status(400).json({ error: 'cam and file required' });
  if (!safeCam(cam) || !safeFile(file)) return res.status(400).json({ error: 'bad name' });
  const full = await resolveFile(cam, file);
  if (!full) return res.status(404).json({ error: 'recording not found' });

  const uploadId = startYouTubeUpload(full, {
    title: title || file.replace('.mp4', ''),
    description: description || '',
    privacy: privacy || 'private',
  });
  res.json({ uploadId });
});

app.get('/api/youtube/upload/:id', (req, res) => {
  const job = uploadJobs.get(req.params.id);
  if (!job) return res.status(404).json({ error: 'upload not found' });
  res.json(job);
});

app.listen(PORT, () => {
  console.log(`recordings-web listening on :${PORT}`);
  console.log(`recordings dir: ${RECORDINGS_DIR}`);
  console.log(`delete enabled: ${ALLOW_DELETE}`);
});
