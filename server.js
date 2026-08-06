/**
 * Lumi - 后端服务
 * 功能：托管静态前端页面、生成 Apple MusicKit JWT 开发者令牌、提供配置 API
 */

const express = require('express');
const jwt = require('jsonwebtoken');
const path = require('path');
const fs = require('fs');
const { execFile } = require('child_process');

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
        let value = trimmed.substring(eqIdx + 1).trim();
        // 处理双引号包裹的值（含转义换行）
        if (value.startsWith('"') && value.endsWith('"')) {
          value = value.slice(1, -1).replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
        }
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

// ============ 输入校验工具 ============
const FIELD_LIMITS = {
  teamId: 64,
  keyId: 64,
  privateKey: 8192,
};

// 校验 PEM 格式私钥（仅接受 PRIVATE KEY / EC PRIVATE KEY）
function isValidPEM(key) {
  const trimmed = key.trim();
  // 仅允许私钥相关的 PEM 标记
  const pemRegex = /^-----BEGIN (?:EC )?PRIVATE KEY-----\n([A-Za-z0-9+/=\n\r]+)\n-----END (?:EC )?PRIVATE KEY-----$/;
  if (!pemRegex.test(trimmed)) return false;
  // 提取 base64 内容并验证可解码为非空数据
  const base64Content = trimmed.split('\n').slice(1, -1).join('').replace(/[\r\s]/g, '');
  if (!base64Content) return false;
  try {
    const decoded = Buffer.from(base64Content, 'base64');
    return decoded.length > 10; // ES256 私钥至少有几个字节
  } catch {
    return false;
  }
}

// 校验字段非空且长度不超限
function validateField(value, name, maxLen) {
  if (typeof value !== 'string' || !value.trim()) {
    return `${name} 为必填项`;
  }
  if (value.length > maxLen) {
    return `${name} 长度不能超过 ${maxLen} 个字符`;
  }
  return null;
}

// 校验 .env 内容语法：每行应为空行、注释或 KEY=VALUE
function isValidEnvSyntax(content) {
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx <= 0) return { valid: false, line: i + 1, reason: `第 ${i + 1} 行格式无效: "${trimmed.substring(0, 40)}"` };
    const key = trimmed.substring(0, eqIdx).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      return { valid: false, line: i + 1, reason: `第 ${i + 1} 行包含无效的键名: "${key}"` };
    }
  }
  return { valid: true };
}

// 对值进行 env 安全转义（处理多行私钥中的换行）
function escapeEnvValue(value) {
  // 如果值包含换行，用双引号包裹并转义内部特殊字符
  if (value.includes('\n')) {
    return '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
  }
  return value;
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

  // 1. 必填 & 长度校验
  const fieldErrors = [
    validateField(teamId, '团队 ID (teamId)', FIELD_LIMITS.teamId),
    validateField(keyId, 'Key ID (keyId)', FIELD_LIMITS.keyId),
    validateField(privateKey, '私钥 (privateKey)', FIELD_LIMITS.privateKey),
  ].filter(Boolean);
  if (fieldErrors.length > 0) {
    return res.status(400).json({ error: fieldErrors.join('；') });
  }

  // 2. PEM 格式校验
  if (!isValidPEM(privateKey)) {
    return res.status(400).json({
      error: '私钥格式无效，需要有效的 PEM 格式（以 -----BEGIN PRIVATE KEY----- 开头，-----END PRIVATE KEY----- 结尾）',
    });
  }

  // 3. 构造 .env 内容并做语法检查
  const envContent =
`# Apple MusicKit 凭据（由 Lumi 自动生成）
APPLE_TEAM_ID=${escapeEnvValue(teamId)}
APPLE_KEY_ID=${escapeEnvValue(keyId)}
APPLE_PRIVATE_KEY=${escapeEnvValue(privateKey)}
PORT=${config.port}
`;

  const envCheck = isValidEnvSyntax(envContent);
  if (!envCheck.valid) {
    return res.status(400).json({ error: `生成的 .env 内容语法错误: ${envCheck.reason}` });
  }

  // 4. 写入文件
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

// ============ 旧版激活码换发（包装 license-tool，私钥仅留 Swift 工具侧） ============
// 请求体：{ oldKey, order, device }
// 成功：纯文本返回新激活码 LUMI2-...
app.post('/api/redeem', (req, res) => {
  const { oldKey, order, device, nonce } = req.body || {};
  if (!oldKey || !order || !device) {
    return res.status(400).type('text/plain').send('oldKey、order、device 均为必填');
  }

  // 读取本地 Ed25519 私钥（与 license-tool 同源；生产环境应置于独立后端服务）
  const keyPath = path.join(__dirname, 'Lumi', 'secrets', 'license_private_key.b64');
  let keyB64 = '';
  try { keyB64 = fs.readFileSync(keyPath, 'utf-8').trim(); } catch (e) { /* ignore */ }
  if (!keyB64) {
    return res.status(500).type('text/plain').send('服务端未配置私钥，无法签发新码');
  }

  const env = { ...process.env, LUMI_LICENSE_PRIVATE_KEY: keyB64 };
  if (process.env.LUMI_VALID_ORDERS) env.LUMI_VALID_ORDERS = process.env.LUMI_VALID_ORDERS;
  if (process.env.LUMI_DEVICE_LIMIT) env.LUMI_DEVICE_LIMIT = process.env.LUMI_DEVICE_LIMIT;

  const args = ['run', 'license-tool', 'redeem',
    '--old-key', String(oldKey), '--order', String(order),
    '--device', String(device), '--lifetime'];
  // 透传客户端防重放 nonce（与 license-tool 的 redeem_state 防重放配合）
  if (nonce) args.push('--nonce', String(nonce));
  execFile('swift', args, { cwd: path.join(__dirname, 'Lumi'), env, timeout: 180000 },
    (err, stdout, stderr) => {
      if (err) {
        return res.status(400).type('text/plain').send((stderr || err.message || '换发失败').trim());
      }
      const code = stdout.trim();
      if (!code.startsWith('LUMI2-')) {
        return res.status(400).type('text/plain').send((stderr || '换发失败').trim());
      }
      res.type('text/plain').send(code);
    });
});

// ============ 吊销清单（已用私钥离线签名，直接提供静态文件） ============
// 返回 LUMIRL-<payload>-<sig> 单行文本；客户端验签后用于吊销匹配。
app.get('/api/revocations', (req, res) => {
  const p = path.join(__dirname, 'Lumi', 'secrets', 'revocations.lumi');
  if (!fs.existsSync(p)) {
    return res.status(404).type('text/plain').send('no revocation list published');
  }
  try {
    const raw = fs.readFileSync(p, 'utf-8').trim();
    res.type('text/plain').send(raw);
  } catch (e) {
    res.status(500).type('text/plain').send('read revocation list failed');
  }
});

// ============ 启动服务 ============
app.listen(config.port, () => {
  const mode = (config.teamId && config.keyId && config.privateKey)
    ? '✅ Apple MusicKit 已配置' : '⚠️  凭据未配置，可使用演示模式';
  console.log(`🎵 Lumi 服务已启动: http://localhost:${config.port} (${mode})`);
  console.log(`   Lumi 已集成付费高级功能:`);
  console.log(`   - Claude Code 编程助手   (Claude Sonnet 4 API)`);
  console.log(`   - Codex 代码分析工具     (GPT-4o API)`);
  console.log(`   - 视频下载 MP4/MP3      (yt-dlp, 1800+ 站点)`);
  console.log(`   - 未来所有 AI 功能      (永久访问)`);
});
