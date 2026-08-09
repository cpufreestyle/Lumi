const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');

const { app, isValidPEM, validateField, isValidEnvSyntax, escapeEnvValue, FIELD_LIMITS } = require('../server');

// ============ isValidPEM 单元测试 ============
describe('isValidPEM', () => {
  it('拒绝空字符串', () => {
    assert.equal(isValidPEM(''), false);
  });

  it('拒绝纯文本（非 PEM 格式）', () => {
    assert.equal(isValidPEM('not a pem key'), false);
  });

  it('拒绝 PUBLIC KEY 格式（仅允许 PRIVATE KEY）', () => {
    const pubKey = '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYI\n-----END PUBLIC KEY-----';
    assert.equal(isValidPEM(pubKey), false);
  });

  it('拒绝 base64 内容为空的 PEM', () => {
    const emptyPem = '-----BEGIN PRIVATE KEY-----\n\n-----END PRIVATE KEY-----';
    assert.equal(isValidPEM(emptyPem), false);
  });

  it('拒绝 base64 内容过短的 PEM（< 10 字节）', () => {
    const shortPem = '-----BEGIN PRIVATE KEY-----\nSGk=\n-----END PRIVATE KEY-----';
    assert.equal(isValidPEM(shortPem), false);
  });

  it('接受有效的 EC PRIVATE KEY PEM 格式', () => {
    // 构造一段足够长的 base64 内容（> 10 字节解码后）
    const b64 = Buffer.alloc(32, 'a').toString('base64');
    const pem = `-----BEGIN EC PRIVATE KEY-----\n${b64}\n-----END EC PRIVATE KEY-----`;
    assert.equal(isValidPEM(pem), true);
  });

  it('接受有效的 PRIVATE KEY PEM 格式', () => {
    const b64 = Buffer.alloc(64, 'x').toString('base64');
    const pem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`;
    assert.equal(isValidPEM(pem), true);
  });

  it('处理带首尾空白的 PEM', () => {
    const b64 = Buffer.alloc(32, 'k').toString('base64');
    const pem = `  \n-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n  `;
    assert.equal(isValidPEM(pem), true);
  });
});

// ============ validateField 单元测试 ============
describe('validateField', () => {
  it('拒绝非字符串值（null）', () => {
    const err = validateField(null, 'test', 100);
    assert.equal(err, 'test 为必填项');
  });

  it('拒绝非字符串值（undefined）', () => {
    const err = validateField(undefined, 'test', 100);
    assert.equal(err, 'test 为必填项');
  });

  it('拒绝非字符串值（数字）', () => {
    const err = validateField(123, 'test', 100);
    assert.equal(err, 'test 为必填项');
  });

  it('拒绝空字符串', () => {
    const err = validateField('', 'test', 100);
    assert.equal(err, 'test 为必填项');
  });

  it('拒绝纯空白字符串', () => {
    const err = validateField('   ', 'test', 100);
    assert.equal(err, 'test 为必填项');
  });

  it('拒绝超过最大长度的值', () => {
    const err = validateField('a'.repeat(65), 'teamId', 64);
    assert.equal(err, 'teamId 长度不能超过 64 个字符');
  });

  it('接受有效值', () => {
    assert.equal(validateField('valid', 'test', 100), null);
  });

  it('恰好等于最大长度时接受', () => {
    assert.equal(validateField('a'.repeat(64), 'teamId', 64), null);
  });
});

// ============ isValidEnvSyntax 单元测试 ============
describe('isValidEnvSyntax', () => {
  it('接受有效的 env 内容', () => {
    const result = isValidEnvSyntax('KEY=value\nOTHER=val');
    assert.equal(result.valid, true);
  });

  it('接受包含注释和空行的内容', () => {
    const result = isValidEnvSyntax('# comment\n\nKEY=value\n# another');
    assert.equal(result.valid, true);
  });

  it('拒绝缺少等号的行', () => {
    const result = isValidEnvSyntax('INVALID_LINE');
    assert.equal(result.valid, false);
    assert.ok(result.line);
    assert.ok(result.reason);
  });

  it('拒绝无效键名（数字开头）', () => {
    const result = isValidEnvSyntax('1BAD=value');
    assert.equal(result.valid, false);
  });

  it('拒绝无效键名（含特殊字符）', () => {
    const result = isValidEnvSyntax('KEY-NAME=value');
    assert.equal(result.valid, false);
  });
});

// ============ escapeEnvValue 单元测试 ============
describe('escapeEnvValue', () => {
  it('不转义单行值', () => {
    assert.equal(escapeEnvValue('simple'), 'simple');
  });

  it('转义包含换行的值', () => {
    const result = escapeEnvValue('line1\nline2');
    assert.ok(result.startsWith('"'));
    assert.ok(result.endsWith('"'));
    assert.ok(result.includes('\\n'));
  });

  it('转义双引号和反斜杠', () => {
    const result = escapeEnvValue('a"b\\c\nd');
    assert.ok(result.includes('\\"'));
    assert.ok(result.includes('\\\\'));
  });
});

// ============ FIELD_LIMITS 常量验证 ============
describe('FIELD_LIMITS', () => {
  it('包含必要的字段限制', () => {
    assert.ok(FIELD_LIMITS.teamId > 0);
    assert.ok(FIELD_LIMITS.keyId > 0);
    assert.ok(FIELD_LIMITS.privateKey > 0);
  });
});

// ============ /api/setup 路由测试 ============
describe('POST /api/setup', () => {
  it('缺少所有字段时返回 400', async () => {
    const res = await request(app)
      .post('/api/setup')
      .send({});
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
    assert.ok(res.body.error.includes('必填'));
  });

  it('缺少部分字段时返回 400', async () => {
    const res = await request(app)
      .post('/api/setup')
      .send({ teamId: 'ABC123' });
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
  });

  it('teamId 超过长度限制时返回 400', async () => {
    const b64 = Buffer.alloc(32, 'a').toString('base64');
    const res = await request(app)
      .post('/api/setup')
      .send({
        teamId: 'x'.repeat(65),
        keyId: 'KEYID12345',
        privateKey: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`,
      });
    assert.equal(res.status, 400);
    assert.ok(res.body.error.includes('长度不能超过'));
  });

  it('私钥非 PEM 格式时返回 400', async () => {
    const res = await request(app)
      .post('/api/setup')
      .send({
        teamId: 'ABC123',
        keyId: 'KEYID12345',
        privateKey: 'not-a-pem-key-but-long-enough-to-pass-length-check-validation',
      });
    assert.equal(res.status, 400);
    assert.ok(res.body.error.includes('PEM'));
  });

  it('私钥为空字符串时返回 400', async () => {
    const res = await request(app)
      .post('/api/setup')
      .send({
        teamId: 'ABC123',
        keyId: 'KEYID12345',
        privateKey: '',
      });
    assert.equal(res.status, 400);
    assert.ok(res.body.error.includes('必填'));
  });

  it('Content-Type 为 application/json', async () => {
    const res = await request(app)
      .post('/api/setup')
      .send({});
    assert.ok(res.headers['content-type'].includes('application/json'));
  });
});

// ============ /api/token 路由测试 ============
describe('GET /api/token', () => {
  it('返回 JSON 响应（含 token 或 error）', async () => {
    const res = await request(app).get('/api/token');
    // 凭据有效时返回 200 + token；无效/缺失时返回 500 + error
    if (res.status === 200) {
      assert.ok(res.body.token);
      assert.ok(res.body.expiresAt);
    } else {
      assert.equal(res.status, 500);
      assert.ok(res.body.error);
      assert.ok(res.body.hint);
    }
  });

  it('响应包含 JSON 格式', async () => {
    const res = await request(app).get('/api/token');
    assert.ok(res.headers['content-type'].includes('application/json'));
  });
});

// ============ /api/redeem 路由测试 ============
describe('POST /api/redeem', () => {
  it('缺少所有字段时返回 400', async () => {
    const res = await request(app)
      .post('/api/redeem')
      .send({});
    assert.equal(res.status, 400);
    assert.ok(res.text.includes('必填'));
  });

  it('缺少 oldKey 时返回 400', async () => {
    const res = await request(app)
      .post('/api/redeem')
      .send({ order: '123', device: 'abc' });
    assert.equal(res.status, 400);
    assert.ok(res.text.includes('必填'));
  });

  it('缺少 order 时返回 400', async () => {
    const res = await request(app)
      .post('/api/redeem')
      .send({ oldKey: 'KEY', device: 'abc' });
    assert.equal(res.status, 400);
    assert.ok(res.text.includes('必填'));
  });

  it('缺少 device 时返回 400', async () => {
    const res = await request(app)
      .post('/api/redeem')
      .send({ oldKey: 'KEY', order: '123' });
    assert.equal(res.status, 400);
    assert.ok(res.text.includes('必填'));
  });

  it('响应类型为 text/plain', async () => {
    const res = await request(app)
      .post('/api/redeem')
      .send({});
    assert.ok(res.headers['content-type'].includes('text/plain'));
  });

  it('请求体为空对象时返回 400', async () => {
    const res = await request(app)
      .post('/api/redeem')
      .send({ oldKey: '', order: '', device: '' });
    assert.equal(res.status, 400);
  });
});

// ============ /api/config-status 路由测试 ============
describe('GET /api/config-status', () => {
  it('返回配置状态', async () => {
    const res = await request(app).get('/api/config-status');
    assert.equal(res.status, 200);
    assert.ok('configured' in res.body);
    assert.ok('hasPrivateKey' in res.body);
  });

  it('不暴露完整的凭据', async () => {
    const res = await request(app).get('/api/config-status');
    // teamId 和 keyId 应该是脱敏的（含 ***）或 null
    if (res.body.teamId) {
      assert.ok(res.body.teamId.includes('***'));
    }
    if (res.body.keyId) {
      assert.ok(res.body.keyId.includes('***'));
    }
  });
});
