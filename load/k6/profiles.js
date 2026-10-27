// Three load profiles through the public host (ALB + WAF -> ingress-nginx -> services), one request mix:
//   idle     1 request every 5 s for 15 min: the platform up with nobody on it (baseline for resources and cost)
//   normal   40 req/s for 12 min (~300 people browsing with ~7.5 s between clicks)
//   extreme  150 -> 400 -> 800 req/s: pushes every HPA to its ceiling and the edge nodes past their pod slots
// Arrival-rate executors: the offered load stays the same when the system slows down; when k6 cannot keep up it
// counts dropped_iterations instead of quietly sending less.
//
//   BASE_URL=https://host PROFILE=normal DEMO_EMAIL=… DEMO_PASSWORD=… k6 run load/k6/profiles.js
//   bash load/run.sh <profile> does that, plus the cluster timeline and CloudWatch (load/README.md).
// SCALE=0.5 multiplies every rate (tuning without editing).
// Reads only: nothing here enrolls, pays or resets (those send real mail and touch Stripe).
// A single source IP trips the WAF's per-IP rate rule above ~33 req/s: raise waf_rate_limit for normal and extreme.
import http from "k6/http";
import { check, fail } from "k6";
import { Counter } from "k6/metrics";

const BASE = __ENV.BASE_URL || "http://localhost:8080";
const PROFILE = __ENV.PROFILE || "normal";
const SCALE = Number(__ENV.SCALE || 1);
const rate = (r) => Math.max(1, Math.round(r * SCALE));

const codes = new Counter("status_by_code");

const profiles = {
  idle: {
    executor: "constant-arrival-rate",
    rate: 1, timeUnit: "5s", duration: __ENV.DURATION || "15m",
    preAllocatedVUs: 2, maxVUs: 10,
  },
  normal: {
    executor: "ramping-arrival-rate",
    startRate: 0, timeUnit: "1s",
    stages: [
      { duration: "2m", target: rate(40) },
      { duration: "12m", target: rate(40) },
      { duration: "1m", target: 0 },
    ],
    preAllocatedVUs: 50, maxVUs: 400,
  },
  extreme: {
    executor: "ramping-arrival-rate",
    startRate: 0, timeUnit: "1s",
    stages: [
      { duration: "2m", target: rate(150) },
      { duration: "3m", target: rate(400) },
      { duration: "4m", target: rate(400) },
      { duration: "2m", target: rate(800) },
      { duration: "3m", target: rate(800) },
      { duration: "1m", target: 0 },
    ],
    preAllocatedVUs: 400, maxVUs: 1500,
  },
};
if (!profiles[PROFILE]) fail(`PROFILE must be one of ${Object.keys(profiles).join(", ")}`);

// The mix (weights add up to 100). OG images are rare in real traffic (link previews), but each one is a JPEG render.
const endpoints = [
  { name: "events_list", weight: 25, path: () => "/api/events", json: "items" },
  { name: "event_detail", weight: 25, path: (e) => `/api/events/${e.slug}`, json: "id" },
  { name: "availability", weight: 15, path: (e) => `/api/regis/events/${e.id}/availability`, array: true },
  { name: "web", weight: 12, path: (e) => (Math.random() < 0.5 ? "/" : `/events/${e.slug}`) },
  { name: "my_tickets", weight: 10, path: () => "/api/regis/tickets/mine", cookie: true, json: "tickets" },
  { name: "categories", weight: 8, path: () => "/api/events/categories", array: true },
  { name: "og_event", weight: 2, path: (e) => `/api/events/og/events/${e.id}` },
  { name: "health", weight: 3, path: () => `/api/${["auth", "events", "regis", "payment"][Math.floor(Math.random() * 4)]}/health` },
];
const total = endpoints.reduce((n, e) => n + e.weight, 0);

export const options = {
  scenarios: { [PROFILE]: profiles[PROFILE] },
  // one threshold per endpoint, so the summary carries per-endpoint numbers; extreme is meant to fail some of them
  thresholds: Object.fromEntries([
    ["http_req_failed", ["rate<0.01"]],
    ["http_req_duration", ["p(95)<1000"]],
    ...endpoints.flatMap((e) => [
      [`http_req_failed{endpoint:${e.name}}`, ["rate<0.01"]],
      [`http_req_duration{endpoint:${e.name}}`, ["p(95)<1000"]],
    ]),
    ...[200, 401, 403, 404, 429, 500, 502, 503, 504].map((c) => [`status_by_code{code:${c}}`, ["count>=0"]]),
  ]),
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
};

export function setup() {
  const list = http.get(`${BASE}/api/events`);
  if (list.status !== 200) fail(`GET /api/events answered ${list.status}`);
  const events = list.json("items").map((e) => ({ id: e.id, slug: e.slug }));
  if (!events.length) fail("no public events: seed the demo first (make demo)");

  let cookie = "";
  if (__ENV.DEMO_EMAIL && __ENV.DEMO_PASSWORD) {
    const res = http.post(`${BASE}/api/auth/sign-in/email`,
      JSON.stringify({ email: __ENV.DEMO_EMAIL, password: __ENV.DEMO_PASSWORD }),
      { headers: { "content-type": "application/json", origin: BASE } });
    const name = Object.keys(res.cookies).find((n) => n.endsWith("session_token"));
    if (res.status !== 200 || !name) fail(`demo sign-in answered ${res.status}`);
    cookie = `${name}=${res.cookies[name][0].value}`;
  }
  return { events, cookie };
}

function pick() {
  let n = Math.random() * total;
  for (const e of endpoints) if ((n -= e.weight) < 0) return e;
  return endpoints[0];
}

export default function (data) {
  let e = pick();
  if (e.cookie && !data.cookie) e = endpoints[0];
  const ev = data.events[Math.floor(Math.random() * data.events.length)];
  const res = http.get(`${BASE}${e.path(ev)}`, {
    headers: e.cookie ? { cookie: data.cookie } : {},
    tags: { endpoint: e.name },
  });
  codes.add(1, { code: String(res.status) });
  check(res, {
    "status 200": (r) => r.status === 200,
    ...(e.json ? { [`body has ${e.json}`]: (r) => r.status !== 200 || e.json in r.json() } : {}),
    ...(e.array ? { "body is an array": (r) => r.status !== 200 || Array.isArray(r.json()) } : {}),
  });
}
