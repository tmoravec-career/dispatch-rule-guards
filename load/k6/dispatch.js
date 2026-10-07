// Dispatch Rules Guard: k6 load script (docs/specs/LOAD_TEST_CRITERIA.md, OPEN_QUESTIONS.md Q40, Q49).
//
//   k6 run -e K6_PROFILE=smoke -e K6_API_TOKEN=<ops token> \
//          --summary-export reports/k6/k6-summary-smoke.json load/k6/dispatch.js
//
// Environment:
//   K6_PROFILE         smoke (default) | load | storm | soak | stress
//   K6_BASE_URL        default http://localhost:3000
//   K6_API_TOKEN       an `ops` Bearer token (never committed; DISPATCH_API_TOKENS on the app)
//   K6_RUN_ID          claim-number prefix for this run (default: generated); [A-Za-z0-9]{1,12}
//   K6_SOAK_DURATION   soak length, default 2m (CI); e.g. 2h for a manual or weekly soak
//   K6_VU_SCALE        multiplies every VU target (default 1); local runs only, e.g. 0.25
//   K6_DURATION_SCALE  multiplies every stage duration except soak's (default 1); local runs only
//
// A run fails ONLY through the thresholds below. There is no fail(), abort or exit here:
// a failing check feeds the `checks` threshold and the run carries on. k6 exits 99 when a
// threshold fails. Every run is followed by bin/capacity_audit (the real gate for the
// read-then-write race), run by the Cucumber steps and by CI, never by this script.
//
// Only the JSON API is exercised. The work-queue HTML page (`/`, `/claims`) is unpaginated
// by design (Q35), so its cost grows with the claims this very run creates; it is kept out
// of every latency budget by never being requested here.

import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';

const PROFILE = __ENV.K6_PROFILE || 'smoke';
const BASE_URL = (__ENV.K6_BASE_URL || 'http://localhost:3000').replace(/\/+$/, '');
const TOKEN = __ENV.K6_API_TOKEN || '';
const VU_SCALE = positiveNumber('K6_VU_SCALE', 1);
const DURATION_SCALE = positiveNumber('K6_DURATION_SCALE', 1);
const SOAK_DURATION = __ENV.K6_SOAK_DURATION || '2m';

const REASON_CODES = ['assigned', 'no_qualified_adjuster', 'qualified_adjusters_at_capacity'];
const UNASSIGNED_REASON_CODES = ['no_qualified_adjuster', 'qualified_adjusters_at_capacity'];
const CAT_STATES = ['TX', 'FL', 'LA'];
// Weighted by rough claim volume, like the engine's ScenarioGenerator; includes states no
// seeded adjuster is licensed in, so some claims are legitimately unassigned.
const STATES = { TX: 18, FL: 16, CA: 16, NY: 10, LA: 7, AZ: 7, GA: 7, NV: 5, NJ: 5, CO: 3, WY: 2 };
const LINES = { auto: 55, property: 35, liability: 10 };

// The only thresholds of every gating profile.
const THRESHOLDS = {
  // Fewer than 1% of requests may fail (non-2xx/3xx or a network error).
  http_req_failed: ['rate<0.01'],
  // p95, not the average. An average hides the tail: one request in 20 could take 2 s
  // while the mean still looks healthy. Dispatch's slow cases ARE the tail: a retry after
  // losing the conditional UPDATE on an adjuster's last free slot, a wait on SQLite's busy
  // timeout for the write lock, contention during a CAT burst. p95 is what a busy adjuster
  // or an integration actually feels, and on a 30-second smoke run it is stable enough to
  // gate on, where p99 would swing on a handful of requests.
  http_req_duration: ['p(95)<300'],
  // More than 99% of checks (status, content type, body shape) must pass.
  checks: ['rate>0.99'],
};

// --- Profiles: only the VU shape differs; every one runs the same iteration below. ---

function seconds(s) {
  return Math.max(1, Math.round(s * DURATION_SCALE));
}

function vus(n) {
  return Math.max(1, Math.ceil(n * VU_SCALE));
}

function smoke() {
  return { smoke: { executor: 'constant-vus', vus: vus(1), duration: `${seconds(30)}s` } };
}

// Ramp 0 -> 20 VUs over 2 m, hold 20 for 5 m, ramp down to 0 over 1 m.
function load() {
  return {
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: `${seconds(120)}s`, target: vus(20) },
        { duration: `${seconds(300)}s`, target: vus(20) },
        { duration: `${seconds(60)}s`, target: 0 },
      ],
      gracefulRampDown: '5s',
    },
  };
}

// A hurricane landfall: 5 VUs of normal claims for 2 m, a burst to 60 VUs within 15 s held
// for 2 m sending only CAT property claims in TX/FL/LA, then 5 VUs of normal claims for 3 m.
function storm() {
  const baseline = seconds(120);
  const rise = seconds(15);
  const hold = seconds(120);
  const recovery = seconds(180);
  return {
    storm_baseline: { executor: 'constant-vus', vus: vus(5), duration: `${baseline}s`, gracefulStop: '5s' },
    storm_burst: {
      executor: 'ramping-vus',
      startTime: `${baseline}s`,
      startVUs: vus(5),
      stages: [
        { duration: `${rise}s`, target: vus(60) },
        { duration: `${hold}s`, target: vus(60) },
      ],
      gracefulRampDown: '5s',
      gracefulStop: '5s',
    },
    storm_recovery: {
      executor: 'constant-vus',
      startTime: `${baseline + rise + hold}s`,
      vus: vus(5),
      duration: `${recovery}s`,
      gracefulStop: '5s',
    },
  };
}

// Moderate load for a configurable time: leaks, pool exhaustion, counter drift.
function soak() {
  return { soak: { executor: 'constant-vus', vus: vus(10), duration: SOAK_DURATION } };
}

// 10 -> 20 -> 40 -> 80 -> 160 -> 320 VUs, 1 m per step (a 1 s climb, then a hold). Each
// iteration is tagged with its step (step<N>_vus<V>), so bin/stress_run can report p95 and
// the error rate per step.
const STRESS_STEPS = [10, 20, 40, 80, 160, 320];
const STRESS_STEP_SECONDS = seconds(60);
const STRESS_STEP_NAMES = STRESS_STEPS.map((n, i) => `step${i + 1}_vus${vus(n)}`);

function stress() {
  const stages = [];
  STRESS_STEPS.forEach((n) => {
    stages.push({ duration: '1s', target: vus(n) });
    stages.push({ duration: `${Math.max(1, STRESS_STEP_SECONDS - 1)}s`, target: vus(n) });
  });
  return { stress: { executor: 'ramping-vus', startVUs: 0, stages, gracefulRampDown: '5s', gracefulStop: '5s' } };
}

function tagStressStep() {
  const elapsedMs = Date.now() - exec.scenario.startTime;
  const index = Math.min(STRESS_STEPS.length - 1, Math.floor(elapsedMs / (STRESS_STEP_SECONDS * 1000)));
  exec.vu.metrics.tags.step = STRESS_STEP_NAMES[index];
}

const PROFILES = { smoke, load, storm, soak, stress };
if (!PROFILES[PROFILE]) {
  throw new Error(`unknown K6_PROFILE "${PROFILE}"; expected one of ${Object.keys(PROFILES).join(', ')}`);
}
const scenarios = PROFILES[PROFILE]();

// stress is informational (Q49): bin/stress_run reports the breaking point and exits 0.
// The same three thresholds stop the run at the first breach (abortOnFail). The 10 s
// delay keeps the very first requests of a cold app from deciding the breaking point.
// The per-step entries are observers so the summary export carries each step's p95 and
// error rate; they can never fail.
function stressThresholds() {
  const abort = (threshold) => [{ threshold, abortOnFail: true, delayAbortEval: '10s' }];
  const thresholds = {
    http_req_failed: abort(THRESHOLDS.http_req_failed[0]),
    http_req_duration: abort(THRESHOLDS.http_req_duration[0]),
    checks: abort(THRESHOLDS.checks[0]),
  };
  STRESS_STEP_NAMES.forEach((name) => {
    thresholds[`http_req_duration{step:${name}}`] = ['p(95)>=0'];
    thresholds[`http_req_failed{step:${name}}`] = ['rate>=0'];
  });
  return thresholds;
}

export const options = {
  scenarios,
  thresholds: PROFILE === 'stress' ? stressThresholds() : THRESHOLDS,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};

// --- One iteration: create a claim, read it back, check both, think. ---

export function setup() {
  const runId = __ENV.K6_RUN_ID || Date.now().toString(36);
  if (!/^[A-Za-z0-9]{1,12}$/.test(runId)) {
    throw new Error(`K6_RUN_ID must be 1-12 letters or digits, got "${runId}"`);
  }
  return { runId };
}

let claimsThisVu = 0;

export default function (data) {
  if (PROFILE === 'stress') tagStressStep();
  claimsThisVu += 1;
  const vu = exec.vu.idInTest;
  // Unique across the run: VU ids are unique, and the counter spans every scenario a VU runs.
  const claimNumber = `K6-${data.runId}-${vu}-${claimsThisVu}`;
  const claim = exec.scenario.name === 'storm_burst'
    ? catClaim(claimNumber, vu + claimsThisVu)
    : normalClaim(claimNumber);
  const headers = { Authorization: `Bearer ${TOKEN}`, Accept: 'application/json' };

  const created = http.post(`${BASE_URL}/api/claims`, JSON.stringify(claim), {
    headers: Object.assign({ 'Content-Type': 'application/json' }, headers),
    tags: { name: 'POST /api/claims' },
  });
  const createdBody = parseJson(created);
  check(created, {
    'create: status is 201': (r) => r.status === 201,
    'create: content type is JSON': isJson,
    'create: dispatch.status is assigned or unassigned': () => hasKnownStatus(createdBody),
    'create: dispatch.reason_code is a known reason code': () => hasKnownReasonCode(createdBody),
    'create: terminal result (assigned has an adjuster, unassigned has none)': () => isTerminal(createdBody),
  });

  const fetched = http.get(`${BASE_URL}/api/claims/${encodeURIComponent(claimNumber)}`, {
    headers,
    tags: { name: 'GET /api/claims/:claim_number' },
  });
  const fetchedBody = parseJson(fetched);
  check(fetched, {
    'get: status is 200': (r) => r.status === 200,
    'get: content type is JSON': isJson,
    'get: same claim_number': () => !!fetchedBody && !!fetchedBody.claim && fetchedBody.claim.claim_number === claimNumber,
    'get: dispatch.status is assigned or unassigned': () => hasKnownStatus(fetchedBody),
    'get: dispatch.reason_code is a known reason code': () => hasKnownReasonCode(fetchedBody),
    'get: terminal result (assigned has an adjuster, unassigned has none)': () => isTerminal(fetchedBody),
  });

  // Think time ends EVERY iteration (a virtual user's pause, not a test-code sleep).
  sleep(randomBetween(1, 3));
}

// --- Checks ---

function parseJson(res) {
  try {
    return res.json();
  } catch (_) {
    return null;
  }
}

function isJson(res) {
  return String(res.headers['Content-Type'] || '').toLowerCase().startsWith('application/json');
}

function dispatchOf(body) {
  return body && typeof body === 'object' && body.dispatch && typeof body.dispatch === 'object' ? body.dispatch : null;
}

function hasKnownStatus(body) {
  const d = dispatchOf(body);
  return !!d && (d.status === 'assigned' || d.status === 'unassigned');
}

function hasKnownReasonCode(body) {
  const d = dispatchOf(body);
  return !!d && REASON_CODES.includes(d.reason_code);
}

// assigned => adjuster_id is a non-empty string; unassigned => adjuster_id is null and the
// reason code is one of the two unassigned codes.
function isTerminal(body) {
  const d = dispatchOf(body);
  if (!d) return false;
  if (d.status === 'assigned') return typeof d.adjuster_id === 'string' && d.adjuster_id.length > 0;
  if (d.status === 'unassigned') return d.adjuster_id === null && UNASSIGNED_REASON_CODES.includes(d.reason_code);
  return false;
}

// --- Claim generator ---

function randomBetween(min, max) {
  return min + Math.random() * (max - min);
}

// A multiple of `step` in [low, high].
function dollars(low, high, step) {
  return low + Math.floor(Math.random() * (Math.floor((high - low) / step) + 1)) * step;
}

function weighted(weights) {
  const keys = Object.keys(weights);
  let pick = Math.random() * keys.reduce((sum, k) => sum + weights[k], 0);
  for (const key of keys) {
    if (pick < weights[key]) return key;
    pick -= weights[key];
  }
  return keys[keys.length - 1];
}

function normalClaim(claimNumber) {
  const line = weighted(LINES);
  if (line === 'auto') {
    const size = weighted({ small: 25, medium: 50, large: 25 });
    const loss = size === 'small' ? dollars(500, 4999, 100) : size === 'medium' ? dollars(5000, 25000, 100) : dollars(25100, 120000, 500);
    const vehicle = Math.random() < 0.2 ? dollars(60000, 180000, 1000) : dollars(8000, 59000, 500);
    return claimBody(claimNumber, 'auto', loss, vehicle, false, weighted(STATES));
  }
  if (line === 'property') {
    const cat = Math.random() < 0.3;
    return cat
      ? claimBody(claimNumber, 'property', dollars(10000, 150000, 500), null, true, CAT_STATES[Math.floor(Math.random() * 3)])
      : claimBody(claimNumber, 'property', dollars(2000, 90000, 500), null, false, weighted(STATES));
  }
  return claimBody(claimNumber, 'liability', dollars(5000, 100000, 500), null, false, weighted(STATES));
}

// Storm burst: CAT property claims cycling through TX/FL/LA, with losses spread around the
// cat_large_loss threshold of 50,000 (both sides of it, and exactly on it).
function catClaim(claimNumber, n) {
  return claimBody(claimNumber, 'property', dollars(30000, 70000, 500), null, true, CAT_STATES[n % CAT_STATES.length]);
}

function claimBody(claimNumber, line, loss, vehicle, cat, state) {
  return {
    claim_number: claimNumber,
    line_of_business: line,
    estimated_loss: loss,
    vehicle_value: vehicle,
    cat_event: cat,
    loss_state: state,
  };
}

function positiveNumber(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!(value > 0)) throw new Error(`${name} must be a positive number, got "${raw}"`);
  return value;
}
