const test = require('node:test'); const assert = require('node:assert/strict');
const { convertUsage, convertWindow, durationLabel, plan } = require('../usage');
test('detects plans', () => { assert.equal(plan('plus').label, 'ChatGPT Plus'); assert.equal(plan('pro_20x').label, 'ChatGPT Pro 20x'); });
test('labels windows and keeps remaining calibrated', () => { const value = convertWindow({ used_percent: 40, limit_window_seconds: 18000, reset_at: 1800000000 }, 'primary'); assert.equal(value.label, 'Five-hour window'); assert.equal(value.remainingPercent, 60); assert.equal(value.resetAt, 1800000000000); });
test('parses primary and weekly limits', () => { const value = convertUsage({ plan_type:'pro_5x', rate_limit:{ primary_window:{used_percent:30,limit_window_seconds:18000},secondary_window:{used_percent:60,limit_window_seconds:604800} } }); assert.equal(value.plan.label, 'ChatGPT Pro 5x'); assert.equal(value.limits.length, 2); });
test('formats durations', () => assert.equal(durationLabel(604800), '1 week'));
