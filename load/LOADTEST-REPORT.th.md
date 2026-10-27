# รายงาน Load test: production, 2026-10-27

[English](LOADTEST-REPORT.md) · **ภาษาไทย**

ทดสอบโหลด 3 รูปแบบกับระบบ production ที่ **https://eventide.creasy.club** ทุกรอบบันทึกการ autoscale (HPA, pod ที่
ค้าง Pending, จำนวน node แต่ละ tier) และฝั่ง AWS (ALB, WAF, RDS, RDS Proxy, ElastiCache, CPU credit ของ node) ด้วย
ค่าใช้จ่ายของรอบเดียวกันอยู่ใน [docs/COST-REPORT.md](../docs/COST-REPORT.md) ข้อมูลดิบอยู่ที่
[`load/results/2026-10-27/`](results/2026-10-27/)

## คำตอบสั้นๆ

- **HPA (scale pod) ทำงานไหม?** ทำงาน ที่ 150–400 req/s `event` ขึ้นจาก **2 → 8** (เพดาน) ใน 75 วินาที และ
  `registration` **2 → 8** ใน 2.5 นาที ส่วน `web` ขึ้น **1 → 3** ที่ 800 req/s หลังหยุดโหลด 2 นาทีทั้งสามกลับไปที่ค่าต่ำสุด
- **node scale ไหม?** scale ทั้งสอง tier เมื่อ HPA เพิ่ม pod จนเกินช่องของ edge node (`t3.small` รับได้ 11 pod ต่อเครื่อง)
  Cluster Autoscaler เพิ่ม edge node (**2 → 3**) ภายใน 10–20 วินาทีหลัง pod แรกค้าง Pending และ node ใหม่รับ pod ได้ใน
  23–40 วินาทีต่อมา ตัวยิงโหลดที่รันใน cluster ต้องการที่บน egress tier จึงได้ node ของตัวเอง (**1 → 2**) หลังหยุดโหลด
  autoscaler ตัดสินใจถอด edge node ที่เกินภายใน 3–4 นาที และ node หายไปภายใน 4–6 นาที
- **scale ไปถึงเท่าไร?** สูงสุด **`event` 8/8, `registration` 8/8, `web` 3/4 pod; edge 3/4 + egress 2/2 = 5 node**
  (จากเดิม 3)
- **รับไหวไหม?** ที่ **800 req/s** (นาทีที่หนักที่สุด 48,000 request) เวลาตอบจาก ALB ถึง service อยู่ที่
  **≤ 112 ms (p95)** แม้ในนาทีที่แย่ที่สุด CPU ของ RDS สูงสุด **44 %** และ node ประมาณ 40 % สำเร็จ 99.93 % ของ 393,524
  request **error ทั้ง 269 ตัว (0.07 %) มาจากเหตุการณ์เดียว:** Cluster Autoscaler ถอด node กลางโหลดแล้วพา `auth` ทั้ง
  2 replica และ `payment` ตัวเดียวออกไปพร้อมกัน ได้ 503 อยู่ประมาณ 16–20 วินาที (§7 ข้อ 1)
- **จะพังที่ไหน?** ยังไม่ถึงที่ 800 req/s HPA ชนเพดานแล้วแต่ node ยังมี CPU เหลือ ถ้าคำนวณต่อจากตัวเลขที่วัดได้
  ฐานข้อมูลจะตันก่อน ที่ประมาณ 1,800 req/s (§5)

## 1. การตั้งค่า

| | |
|---|---|
| Cluster | EKS **1.35**, node group `edge` (2–4) และ `egress` (1–2) ทั้งหมดเป็น `t3.small` (2 vCPU, 2 GiB, **11 pod ต่อ node**), T3 unlimited |
| Pod autoscaling | HPA ที่ 60 % ของ CPU request: `event` 2–8 (request 50m), `registration` 2–8 (50m), `web` 1–4 (50m) ขาขึ้น: ไม่หน่วง, +100 % หรือ +4 pod ทุก 15 วินาที; ขาลง: หน้าต่าง 60 วินาที, −2 pod ทุก 30 วินาที |
| Node autoscaling | Cluster Autoscaler 1.35.0 (chart 9.59.0) หา node group จาก tag ของ ASG, expander `least-waste`, ถอด node เมื่อไม่ได้ใช้ 2 นาทีและผ่านไป 2 นาทีหลังเพิ่ม node (ค่าสำหรับเดโม ค่าปกติคือ 10 นาที) |
| replica คงที่ | `auth` 2, `payment` 1, `mail-worker` 1 (egress); ingress-nginx 2 (edge) |
| ข้อมูล | RDS PostgreSQL `db.t3.micro` หลัง RDS Proxy, ElastiCache `cache.t3.micro` (TLS + AUTH), `DB_POOL_MAX=4` ต่อ pod |
| Edge | ALB + WAF (5 rule) ยก rate limit ต่อ IP จาก 10,000 เป็น 2,000,000 request ต่อ 5 นาทีเฉพาะตอน normal และ extreme (โหลดทั้งหมดมาจาก IP เดียว) แล้วคืนค่าหลังเทส |
| ชุดข้อมูล | demo ที่เตรียมไว้: 8 event (สาธารณะ 5), 6 หมวดหมู่, 3 บัญชี |
| เครื่องมือ | k6 2.3.0 (`load/k6/profiles.js`), `load/run.sh`, `load/collect.sh` (ดู cluster ทุก ~10 วินาที), `load/cloudwatch.sh` |

**ส่วนผสมของ request** (ทุกโปรไฟล์ น้ำหนักเต็ม 100) อ่านอย่างเดียว ไม่มีการลงทะเบียนหรือจ่ายเงิน เพราะเส้นทางเหล่านั้น
ส่งเมลจริงและเรียก Stripe

| น้ำหนัก | Request | เส้นทางในระบบ |
|---:|---|---|
| 25 | `GET /api/events` | event → RDS Proxy → Postgres |
| 25 | `GET /api/events/:slug` | event → Redis (event cache), ถ้าไม่เจอค่อยไป Postgres |
| 15 | `GET /api/regis/events/:id/availability` | registration → Postgres |
| 12 | `GET /` และ `/events/:slug` | web (Bun server ใส่ head ตาม URL) → event |
| 10 | `GET /api/regis/tickets/mine` (ล็อกอินแล้ว) | registration → session cache ใน Redis (ถ้าไม่เจอถาม auth) → Postgres |
| 8 | `GET /api/events/categories` | event → Postgres |
| 2 | `GET /api/events/og/events/:id` | event เรนเดอร์ JPEG 1200×630 |
| 3 | `/api/*/health` | แต่ละ service ไม่แตะอะไร |

**โปรไฟล์:** `idle` 1 request ทุก 5 วินาที นาน 15 นาที; `normal` 40 req/s นาน 12 นาที (สมมติว่าคนเปิดดูเว็บพร้อมกัน
~300 คน คลิกห่างกัน ~7.5 วินาที); `extreme` 150 → 400 → 800 req/s ใน 15 นาที แล้วปล่อยว่าง 12 นาทีเพื่อดูการ scale ลง
ใช้ executor แบบ arrival-rate โหลดที่ส่งไม่ลดลงแม้ระบบช้า ถ้า k6 ส่งไม่ทันจะนับเป็น `dropped_iterations`

**โหลดมาจากไหน** idle และ normal ยิงจาก laptop ในกรุงเทพ (≈ 270 ms ถึง us-east-1 ซึ่งคือ latency ส่วนใหญ่ในตาราง
ของสองรอบนั้น) extreme รอบแรกจาก laptop เครื่องเดียวกันแสดงว่า **เครือข่ายที่บ้านเป็นตัวจำกัด ไม่ใช่ระบบ** ที่ ~300
req/s การเชื่อมต่อใหม่ไปยัง AWS ถูกปฏิเสธทั้งหมด (`Couldn't connect to server` ทั้ง ALB, Cost Explorer และ EKS API
ขณะที่เว็บอื่นยังเข้าได้) และกลับมาทันทีที่หยุด k6 extreme รอบเต็มจึงรัน **ภายใน AWS**: k6 เป็น Kubernetes Job บน
egress tier แต่ยังยิงเข้า URL สาธารณะ (ออกทาง NAT แล้วกลับเข้ามาทาง ALB และ WAF) ด้วยคำสั่ง
`RUNNER=cluster bash load/run.sh extreme`

## 2. ภาพรวมผล

| | idle | normal | extreme (ใน AWS) |
|---|---:|---:|---:|
| จำนวน request | 182 | 32,150 | 393,524 |
| อัตราที่ทำได้ | 0.2/s | 35.7/s (40 ช่วงคงที่) | เฉลี่ย 437/s, **800/s ช่วงคงที่** |
| ล้มเหลว | 0.00 % | 0.06 % (เครือข่ายฝั่ง client) | 0.07 % (การถอด node ครั้งเดียว, §7) |
| latency ฝั่ง client med / p95 / p99 | 285 / 890 / 1,504 ms | 284 / 757 / 2,520 ms | **9 / 38 / 212 ms** |
| ALB → service p95 นาทีที่แย่ที่สุด | 220 ms | 47 ms | 112 ms |
| 5xx จาก ALB / จาก service | 0 / 0 | 0 / 0 | 0 / 269 |
| pod ของ `event` (ต่ำสุด → สูงสุด) | 2 → 2 | 2 → 3 | **2 → 8** |
| pod ของ `registration` | 2 → 2 | 2 → 2 | **2 → 8** |
| pod ของ `web` | 1 → 1 | 1 → 1 | **1 → 3** |
| node edge / egress (สูงสุด) | 2 / 1 | 2 / 1 | **3 / 2** |
| CPU ของ edge node สูงสุด (`kubectl top`) | 5 % | 8 % | 43 % |
| memory ของ edge node สูงสุด | 52 % | 56 % | 71 % |
| CPU ของ RDS สูงสุด | 6.6 % | 8.5 % | 43.7 % |
| RDS Proxy: client → DB connection สูงสุด | 11 → 6 | 15 → 8 | 38 → 33 |
| Redis hit rate | 76 % | 88 % | 88 % |
| CPU credit ที่ถูกคิดเงิน (node, RDS) | 0 | 0 | 0 |

latency ฝั่ง client ของ extreme วัดจากใน AWS จึงเทียบกับรอบที่ยิงจาก laptop ไม่ได้ แถว ALB คือตัวเลขฝั่ง server ที่เทียบกันได้ทั้งสามรอบ

## 3. idle

`results/2026-10-27/idle/`, 16:52–17:10 UTC

- 182 request ได้ 200 ทั้งหมด ไม่มีอะไร scale: `event` 2, `registration` 2, `web` 1, node 2 + 1 แต่ละ pod ใช้ CPU 2–8 m,
  node 2–5 %, memory ของ edge node ~50 % (node ขนาด 2 GiB)
- ALB นับได้ **430** request ในช่วงนั้น ทั้งที่ k6 ส่งแค่ 182: load balancer สาธารณะตัวใหม่ถูก scanner เจอภายในไม่กี่นาที
  และ WAF **บล็อกเอง 10** request
- RDS เริ่มต้นแทบไม่มี CPU credit (balance ≈ 4) เพราะ `db.t3.micro` ที่สร้างใหม่ต้องสะสมเอง รอบนี้ไม่มีผล (ไม่มี credit
  ถูกคิดเงินในรอบไหนเลย) แต่ถ้าโหลดหนักนานๆ ทันทีหลัง deploy จะถูกคิดเป็น surplus credit
- request ที่ช้าที่สุดคือรูป Open Graph ซึ่งเรนเดอร์ใหม่ทุกครั้ง (median 1.2 วินาทีเมื่อวัดจาก laptop)

## 4. normal (40 req/s)

`results/2026-10-27/normal/`, 17:11–17:28 UTC

| Endpoint | Request | ล้มเหลว | med | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| `GET /api/events` | 8,091 | 0.05 % | 285 | 433 | 2,246 |
| `GET /api/events/:slug` | 7,941 | 0.06 % | 277 | 411 | 2,218 |
| availability | 4,839 | 0.12 % | 290 | 452 | 2,316 |
| web | 3,851 | 0.05 % | 282 | 616 | 2,562 |
| my tickets (ล็อกอินแล้ว) | 3,247 | 0.03 % | 285 | 403 | 2,321 |
| categories | 2,549 | 0.04 % | 280 | 419 | 2,184 |
| health | 973 | 0 % | 276 | 471 | 2,392 |
| รูป OG | 657 | 0 % | 1,433 | 2,802 | 6,554 |

(มิลลิวินาที วัดที่ laptop)

- **server เร็ว ส่วนหางยาวมาจากเครือข่าย** เวลาตอบของ service ที่ ALB วัดไม่เกิน **47 ms** (p95) ทุกนาที และไม่มี 5xx เลย
  request ที่ล้มเหลว 21 ตัว (0.06 %) และ p99 ที่ 2.2–2.5 วินาที ตรงกับจังหวะที่ laptop หลุดการเชื่อมต่อชั่วครู่ที่นาทีที่ 3
  (ตัวเก็บข้อมูล cluster ก็หายไป 2 รอบพร้อมกัน)
- **Autoscaling:** `event` ใช้ CPU ถึง 75 % ของ request ที่นาทีที่ 2 HPA จึง scale **2 → 3** ลดกลับเป็น 2 หลัง ~7 นาที และ
  ขึ้น 2 → 3 → 2 อีกครั้งในภายหลัง `registration` สูงสุด 49 % และ `web` 14 % ไม่เปลี่ยน node ไม่เปลี่ยน ที่ 40 req/s
  แอปทั้งระบบใช้ **≈ 0.2 vCPU** (`event` 140 m, `registration` 49 m, `web` 7 m)
- **Cache และฐานข้อมูล:** Redis hit 23,610 ครั้ง miss 3,262 ครั้ง (88 %) CPU ของ RDS ≤ 8.5 % RDS Proxy รวม 15 client
  connection เหลือ 8 database connection
- **ขนาดต่อ request:** `ProcessedBytes` ของ ALB ÷ จำนวน request = 2.9 KB (request + response) รายงานค่าใช้จ่ายใช้ค่านี้

## 5. extreme (ใน AWS)

`results/2026-10-27/extreme/`, k6 17:48:02–18:03:33 UTC, เก็บข้อมูลต่อถึง 18:15:33

| Endpoint | Request | ล้มเหลว | med | p95 | p99 |
|---|---:|---:|---:|---:|---:|
| `GET /api/events` | 98,412 | 0 % | 10 | 35 | 287 |
| `GET /api/events/:slug` | 98,502 | 0 % | 4.3 | 12 | 74 |
| availability | 59,009 | 0 % | 16 | 47 | 281 |
| web | 47,184 | 0 % | 4.5 | 11 | 45 |
| my tickets (ล็อกอินแล้ว) | 39,431 | **0.38 %** | 11 | 41 | 434 |
| categories | 31,348 | 0 % | 6.9 | 23 | 222 |
| health | 11,763 | **1.00 %** | 3.5 | 9.7 | 63 |
| รูป OG | 7,873 | 0 % | 45 | 146 | 693 |

(มิลลิวินาที วัดจาก pod ใน region เดียวกันผ่าน URL สาธารณะ; status code: 200 × 393,253, 503 × 261, 502 × 4, 504 × 4;
dropped iterations 977 ตัว 0.25 %)

**ลำดับเหตุการณ์การ scale** (จาก Kubernetes events ใน `events.txt` และ log ของ autoscaler)

| UTC | โหลด | เกิดอะไรขึ้น |
|---|---|---|
| 17:47:17 | – | pod ของ k6 (ขอ 1.5 vCPU / 1 GiB) ลงบน egress node ไม่ได้: *Insufficient memory* → Cluster Autoscaler **egress 1 → 2** |
| 17:48:02 | ไต่ไป 150/s | egress node ใหม่พร้อม k6 เริ่มรันบนนั้น |
| 17:48:58 | ~60/s | HPA `event` 2 → 3 |
| 17:49:28 – 17:50:13 | 90–150/s | HPA `event` 3 → 4 → 5 → 6 → **8 (เพดาน)** ใน 75 วินาที; `registration` 2 → 3 |
| 17:50:43 – 17:51:28 | ไต่ไป 400/s | HPA `registration` 3 → 5 → 6; pod ค้าง `Pending`: *"Too many pods"* (edge node ทั้งสองเต็ม) |
| **17:51:39** | ~300/s | **Cluster Autoscaler: edge 2 → 3** |
| 17:52:02 | | edge node ใหม่ลงทะเบียน (23 วินาทีต่อมา) และรับ pod ที่ค้างไว้ |
| 17:52:28 | 400/s | HPA `registration` → **8 (เพดาน)** |
| **17:54:20** | 400/s | **Cluster Autoscaler ถอด egress node ตัวเดิมระหว่างที่ยังมีโหลด** (utilization 0.21 < 0.5): ไล่ `auth` ทั้ง 2 replica, `payment` และ `mail-worker` ออกพร้อมกัน (ข้อค้นพบที่ 1) |
| 17:54:41 – 17:54:45 | 400/s | pod ตัวแทนพร้อมบน egress node อีกตัว **ได้ 503 อยู่ ≈ 16–20 วินาที** กับ request ที่ล็อกอินและ health check ของ auth/payment |
| 17:57:59 – 17:58:44 | ไต่ไป 800/s | HPA `web` 1 → 2 → **3** |
| 17:59 – 18:02 | **800/s** | นิ่ง: `event` 8, `registration` 8, `web` 3, edge 3 node ใช้ CPU ~39 %, CPU ของ RDS ถึง 44 % |
| 18:03:33 | 0 | k6 จบ |
| 18:03:29 – 18:05:15 | 0 | HPA กลับเป็น 2 / 2 / 1 |
| 18:07:11 – 18:07:52 | 0 | Cluster Autoscaler drain และถอด edge node ตัวที่สาม |

**ที่ 800 req/s:** `event` ใช้ ~1.15 vCPU จาก 8 pod (≈ 145 m ต่อ pod คือ 290 % ของ request 50 m แต่ยังต่ำกว่า limit
500 m) `registration` ~0.5 vCPU edge node ทั้งสามใช้ ~39 % ของ 6 vCPU memory ของ edge สูงสุด 71 % CPU ของ RDS 44 %
CPU ของ Redis engine 3.7 % ไม่มี CPU credit ถูกคิดเงินเลย (credit ที่ node และ RDS สะสมไว้พอสำหรับ 15 นาที)

**จะพังที่ไหน** ยังไม่ถึงที่ 800 req/s HPA ติดเพดาน 8 ขณะที่ node ยังใช้ไม่ถึงครึ่ง ขีดจำกัดถัดไปคำนวณต่อจากตัวเลขที่วัดได้
(ไม่ได้วัดจริง):

1. **ฐานข้อมูล:** CPU ของ RDS จาก 8.5 % ที่ 40 req/s เป็น 44 % ที่ 800 req/s ถ้าเพิ่มแบบเส้นตรงจะถึง 100 % ราว
   **~1,800 req/s** และ CPU credit (≈ 5–8) จะหมดภายในไม่กี่นาทีถ้ามีโหลดเกิน baseline 10 % ต่อเนื่อง แล้วถูกคิดเป็น surplus
   credit (§7 ของรายงานค่าใช้จ่าย)
2. **pod ของ `event`:** 8 pod × limit 500 m = 4 vCPU เทียบกับที่ใช้ ~1.15 vCPU เหลือที่ ≈ 3 เท่า
3. **ช่อง pod:** ที่เพดาน edge tier มี pod ของแอปและระบบรวม 23 ตัว edge 3 node ให้ 27 ช่อง node ที่สี่ (เพดานของ node
   group) ให้ 36 ช่อง

## 6. เห็น node autoscaling สองครั้ง: extreme รอบแรก (ยิงจาก laptop)

`results/2026-10-27/extreme-laptop/` โหลดหยุดที่ 17:33:32 เมื่อเครือข่ายของ laptop รับไม่ไหวที่ ~300 req/s แต่ cluster
ผ่านการ scale ขึ้นครบรอบไปแล้ว และช่วงเฝ้าดู 12 นาทีหลังจากนั้นจับการ scale ลงได้

| UTC | เกิดอะไรขึ้น |
|---|---|
| 17:29:29 | เริ่มโหลด (ไต่ไป 150 req/s แล้วไปทาง 400) |
| 17:30:42 | HPA `event` 2 → 4 |
| 17:31:27 | HPA `event` 4 → 7, `registration` 2 → 3 |
| 17:32:12 | HPA `event` 7 → **8 (เพดาน)**, `registration` 3 → 4 |
| 17:32:57 | HPA `registration` 4 → 6: pod ค้าง `Pending` 3 ตัว *"0/3 nodes are available: … 2 Too many pods"* |
| **17:33:07** | **Cluster Autoscaler: "Final scale-up plan: edge 2 → 3 (max 4)"** 10 วินาทีหลัง pod แรกค้าง |
| 17:33:27 | HPA `registration` → **8 (เพดาน)** |
| 17:33:47 | node ใหม่ `ip-10-20-10-45` ลงทะเบียน (40 วินาทีหลังตัดสินใจ) pod 8 + 8 พร้อมครบภายใน 17:34:30 |
| 17:34:42 – 17:35:57 | โหลดหมด HPA ทั้งสองลด 8 → 6 → 4 → 2 |
| **17:37:59** | **Cluster Autoscaler scale ลง**: drain node `ip-10-20-10-194` (2 นาทีหลังเพิ่ม + ไม่ได้ใช้ 2 นาที) |
| 17:40:42 | node หายไป edge กลับเป็น 2 |

ฝั่ง server สะอาดตลอดแม้ laptop จะล้ม: ALB นับ 5xx จาก service และจาก ALB ได้ **0** ในช่วงนั้น การ scale ลงไล่ ingress-nginx
controller ไป 1 ตัว (ถูกสร้างใหม่ทันที อีกตัวรับงานต่อ) และ HPA ของ `web` บันทึก `FailedGetResourceMetric` ~10 วินาที
ระหว่างที่ pod ย้าย ทั้งสองอย่างไม่ทำให้เกิด error

## 7. ข้อค้นพบ

1. **Cluster Autoscaler ทำให้ service ทั้งตัวหายไปได้ระหว่าง scale ลง** ที่ 17:54:20 ขณะโหลด 400 req/s มันถอด egress
   node ตัวเดิมเพราะ pod บนนั้นย้ายไปอยู่ node ใหม่ได้ ไม่มีอะไรห้ามไม่ให้มัน **ไล่ `auth` ทั้ง 2 replica และ `payment`
   ตัวเดียวออกพร้อมกัน** เพราะ chart ไม่มี PodDisruptionBudget ผลคือไม่มี auth อยู่ ~16–20 วินาที (request ที่ล็อกอินได้
   503 `AUTH_UNAVAILABLE`) และไม่มี payment วิธีแก้เล็กและอยู่ใน chart: PodDisruptionBudget `minAvailable: 1` ให้ `auth`
   (และ `event`/`registration` ที่มี ≥ 2 replica) และ annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`
   ให้ pod `payment` ตัวเดียว (ซึ่งตั้งใจให้เป็น `Recreate` และไม่ควรถูกย้ายกลางคัน) เวลา 2 นาทีของเดโมทำให้เกิดง่ายขึ้น
   แต่ไม่ใช่ต้นเหตุ ค่าปกติ (10 นาที) แค่ทำให้มาช้าลง
2. **สิ่งที่ทำให้ต้องเพิ่ม node คือช่อง pod ไม่ใช่ CPU** การเพิ่ม edge node ทุกครั้งเกิดจาก *"Too many pods"*: `t3.small` รับได้
   11 pod (ข้อจำกัดของ VPC CNI) และเมื่อ CPU request เป็น 50 m ตัว scheduler ไม่เคยขาด CPU ก่อน node ใช้ไม่ถึงครึ่งที่ 800
   req/s pod วิ่งที่ ~290 % ของ CPU request เปอร์เซ็นต์ของ HPA จึงบอกแค่ว่า "ยุ่ง" ไม่ได้บอกความจุ ถ้าตั้ง request ให้ตรงกับ
   ที่ใช้จริง (≈ 150 m สำหรับ `event` ตามที่วัดตอนโหลด) scheduler และ HPA จะเห็นความจุจริง แลกกับ pod ต่อ node ที่น้อยลง
3. **HPA ชนเพดาน 8 ตั้งแต่ระบบยังไม่มีปัญหา** `event` อยู่ที่ 8 ตั้งแต่ 150 req/s เมื่อมี Cluster Autoscaler แล้ว กฎ
   "เพดาน 8 เพราะ `t3.medium` รับได้ 17 pod" ไม่ใช่ตัวจำกัดอีกต่อไป การยกเพดาน (และลด `DB_POOL_MAX` ตาม โดยให้ RDS
   Proxy รับส่วนที่เหลือ) คือคันโยกถัดไป
4. **ได้ความจุใหม่เร็ว** จาก Pending ถึง node ใหม่ลงทะเบียน: 23–40 วินาที การตัดสินใจ scale เกิด 10–20 วินาทีหลัง pod แรก
   ค้าง image จาก ECR ดึงผ่าน VPC endpoint ได้ในไม่กี่วินาที
5. **laptop เครื่องเดียวไม่ใช่ load generator** เครือข่ายที่บ้านปฏิเสธการเชื่อมต่อไป AWS ทั้งหมดที่ ~300 req/s สำหรับรอบที่ยิง
   จาก laptop ให้เชื่อตัวเลขฝั่ง server (ALB, CloudWatch) อะไรที่หนักกว่านั้นต้องรันใน region
6. **load balancer สาธารณะตัวใหม่ถูก scan ทันที** request ที่ไม่ได้ส่งเอง 248 ตัวในช่วง idle WAF บล็อก 10 ตัว rate limit
   ต่อ IP (10,000 ต่อ 5 นาที ≈ 33 req/s) ต่ำพอที่สำนักงานหนึ่งที่ออกเน็ตผ่าน NAT เดียวกันอาจโดนบล็อกตอนพีค ยกค่านี้
   เฉพาะตอนเทส
7. **cache ทำงานได้ดี** Redis hit rate 88 % ตอนโหลด RDS เห็น 33 connection ผ่าน proxy จาก 38 client connection (pod ที่ใช้
   ฐานข้อมูล 19 ตัว × `DB_POOL_MAX` 4 จะเปิดได้ถึง 76 ถ้าไม่มี proxy)

## 8. ข้อจำกัด

- รันโปรไฟล์ละครั้งเดียว เหตุการณ์ scale และตัวเลขระดับหลักสิบเท่าห่างจาก noise มาก แต่ต่างกันไม่กี่เปอร์เซ็นต์ไม่ได้
- อ่านอย่างเดียว ไม่มีการลงทะเบียน การจองที่นั่ง หรือการจ่ายเงิน (ซึ่งเขียน lock แถว และส่งเมล)
- idle และ normal ยิงจาก laptop เครื่องเดียว IP เดียว ห่าง ≈ 270 ms latency ฝั่ง client ส่วนใหญ่จึงเป็นของเครือข่าย
- ตัวยิงที่อยู่ใน cluster เข้าเว็บผ่าน NAT gateway และ IP สาธารณะของ ALB ผู้ใช้จริงไม่ผ่าน NAT ค่าใช้จ่ายส่วนนั้นจึงเป็นของ
  การเทส (แยกไว้ในรายงานค่าใช้จ่าย) และ node ของตัวยิงเองไม่ใช่สิ่งที่ production ต้องใช้
- ลดเวลาการ scale ลงของ Cluster Autoscaler เพื่อเดโม (2 นาทีแทน 10 นาที)
- ตัวเลข "จะพังที่ไหน" ใน §5 เป็นการคำนวณต่อ ไม่ได้วัดจริง

## 9. ทำซ้ำ

```sh
bash load/run.sh idle
terraform -chdir=infra/terraform apply -var waf_rate_limit=2000000    # โหลดทั้งหมดมาจาก IP เดียว
bash load/run.sh normal
RUNNER=cluster bash load/run.sh extreme                                 # k6 เป็น Job ใน cluster
terraform -chdir=infra/terraform apply                                  # คืน WAF limit เป็น 10,000 ต่อ 5 นาที
```

แต่ละรอบมี `summary.json` (k6), `dashboard.html` (รายงาน HTML ของ k6 พร้อมกราฟตามเวลา), `timeline.csv` (cluster ทุก ~10
วินาที), `events.txt` และ `autoscaler.log` (การตัดสินใจ scale) และ `cloudwatch-summary.tsv`
