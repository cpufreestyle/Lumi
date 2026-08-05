/**
 * Lumi - 后端服务
 * 功能：托管静态前端页面、生成 Apple MusicKit JWT 开发者令牌、提供配置 API
 */

const express = require('express');
const jwt = require('jsonwebtoken');
const path = require('path');
const fs = require('fs');

// ============ 加载配置 ============
function loadConfig() {
  const envPath = path.join(__dirname, '.env');
  if (fs.existsSync(envPath)) {
    const content = fs.readFileSync(envPath, 'utf-8');
    content.split('\n').forEach(line => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx > 0) {
        const key = trimmed.substring(0, eqIdx).trim();
        const value = trimmed.substring(eqIdx + 1).trim();
        if (!process.env[key]) process.env[key] = value;
      }
    });
  }

  return {
    teamId: process.env.APPLE_TEAM_ID || '',
    keyId: process.env.APPLE_KEY_ID || '',
    privateKey: process.env.APPLE_PRIVATE_KEY || '',
    port: parseInt(process.env.PORT || '3000'),
  };
}

const config = loadConfig();

// ============ Express App ============
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname)));

app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

// ============ 令牌缓存 ============
let cachedToken = null;
let tokenExpiry = 0;

// 生成 Apple MusicKit JWT 开发者令牌（ES256，最长 6 个月有效期）
function generateDeveloperToken() {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && tokenExpiry > now + 300) return cachedToken;

  if (!config.teamId || !config.keyId || !config.privateKey) {
    throw new Error('未配置 Apple Developer 凭据，请编辑 .env 文件');
  }

  const maxAge = 15777000; // ~6 months in seconds
  const token = jwt.sign(
    { iss: config.teamId, iat: now, exp: now + maxAge },
    config.privateKey,
    { algorithm: 'ES256', header: { alg: 'ES256', kid: config.keyId } }
  );

  cachedToken = token;
  tokenExpiry = now + maxAge;
  return token;
}

// ============ API 路由 ============
app.get('/api/token', (req, res) => {
  try {
    const token = generateDeveloperToken();
    res.json({ token, expiresAt: tokenExpiry * 1000 });
  } catch (err) {
    res.status(500).json({
      error: err.message,
      hint: '请确保 .env 文件中已配置 APPLE_TEAM_ID、APPLE_KEY_ID、APPLE_PRIVATE_KEY',
    });
  }
});

app.get('/api/config-status', (req, res) => {
  const hasCredentials = !!(config.teamId && config.keyId && config.privateKey);
  res.json({
    configured: hasCredentials,
    teamId: config.teamId ? `${config.teamId.slice(0, 2)}***${config.teamId.slice(-2)}` : null,
    keyId: config.keyId ? `${config.keyId.slice(0, 2)}***${config.keyId.slice(-2)}` : null,
    hasPrivateKey: !!config.privateKey,
  });
});

app.post('/api/setup', (req, res) => {
  const { teamId, keyId, privateKey } = req.body;

  if (!teamId || !keyId || !privateKey) {
    return res.status(400).json({ error: '团队 ID、Key ID 和私钥均为必填项' });
  }

  const envContent =
`# Apple MusicKit 凭据（由 Lumi 自动生成）
APPLE_TEAM_ID=${teamId}
APPLE_KEY_ID=${keyId}
APPLE_PRIVATE_KEY=${privateKey}
PORT=${config.port}
`;
  fs.writeFileSync(path.join(__dirname, '.env'), envContent);

  config.teamId = teamId;
  config.keyId = keyId;
  config.privateKey = privateKey;
  process.env.APPLE_TEAM_ID = teamId;
  process.env.APPLE_KEY_ID = keyId;
  process.env.APPLE_PRIVATE_KEY = privateKey;

  cachedToken = null;
  tokenExpiry = 0;

  try {
    const token = generateDeveloperToken();
    res.json({ success: true, message: '凭据已保存并验证成功', token });
  } catch (err) {
    res.json({ success: true, warning: `凭据已保存但令牌生成失败: ${err.message}` });
  }
});

// ============ 启动服务 ============
app.listen(config.port, () => {
  const mode = (config.teamId && config.keyId && config.privateKey)
    ? '✅ Apple MusicKit 已配置' : '⚠️  凭据未配置，可使用演示模式';
  console.log(`🎵 Lumi 服务已启动: http://localhost:${config.port} (${mode})`);
});
