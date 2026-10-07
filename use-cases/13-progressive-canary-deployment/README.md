# 13 — Progressive Canary Deployment

Lab 06 แสดง weighted routing แบบ static 80/20 ส่วน lab นี้ทำ canary deployment แบบที่ใช้จริง: ค่อย ๆ เพิ่ม traffic ไป release ใหม่ทีละขั้น `0 → 10 → 25 → 50 → 100%` ผ่าน Dynamic RDS โดยไม่ restart Envoy ทุกขั้นต้องผ่าน analysis gate ที่อ่าน metrics จริงจาก Envoy และถ้า canary มี 5xx rate เกิน policy controller จะ rollback กลับ 0% เองโดยไม่ต้องรอคน

## สถาปัตยกรรม

```text
Client :8080 -> Nginx -> Envoy :10000 --(100-w)%--> backend_stable  (VERSION-1)
                    |                 \---- w% ---> backend_canary  (VERSION-2)
                    \-> Canary Console (/deployment/)
                             |  publish routes-current.yaml (atomic rename)
                             |  read config_dump + /stats (upstream_rq_completed, upstream_rq_5xx)
                             v
                        Envoy Admin :9901
```

| ไฟล์ | หน้าที่ |
|---|---|
| `envoy.yaml` | Bootstrap: CDS/RDS จากไฟล์ใน `xds/` |
| `xds/clusters.yaml` | CDS: `backend_stable`, `backend_canary` |
| `xds/routes-baseline.yaml` | RDS เริ่มต้น: canary 0% + header override |
| `xds/routes-current.yaml` | RDS ที่ Envoy ใช้จริง controller เขียนทับแบบ atomic |
| `deployment-ui/server.py` | Canary controller: step, analysis gate, auto-rollback |
| `backend/backend.py` | Backend ที่ inject HTTP 500 ได้ผ่าน control port `9000` ภายใน Compose network |

> Nginx และ Envoy Admin bind ที่ `127.0.0.1` เท่านั้น Console ไม่มีระบบบัญชีและออกแบบสำหรับ local operator lab ห้ามเปิดสู่ public network

## Route ที่ controller สร้าง

```yaml
routes:
  - match: { prefix: "/", headers: [{ name: x-canary, string_match: { exact: always } }] }
    route: { cluster: backend_canary }            # tester เข้าหา canary ได้ทุกขั้น
  - match: { prefix: "/" }
    route:
      weighted_clusters:
        clusters:
          - { name: backend_stable, weight: 75 }   # 100 - w
          - { name: backend_canary, weight: 25 }   # w
```

Controller เขียนไฟล์นี้ใหม่ทุกครั้งที่เปลี่ยนขั้น เพิ่ม `version_info` แล้วรอจนเห็น revision นั้นใน `config_dump` ถ้า Envoy ไม่ยอมรับภายใน 12 วินาทีจะคืนไฟล์เดิม

## Analysis gate และ auto-rollback

ทุกครั้งที่ Envoy ยอมรับ weight ใหม่ controller จะ snapshot counter `cluster.<name>.upstream_rq_completed` และ `upstream_rq_5xx` แล้วคิด error rate จากส่วนต่างหลัง snapshot นั้น (analysis window = ขั้นปัจจุบัน)

| เงื่อนไข | ค่าเริ่มต้น (env ใน Compose) | ผล |
|---|---|---|
| Canary ตอบ `/healthz` | — | ต้องผ่านก่อน advance ทุกขั้น; ถ้าล้มระหว่าง rollout → rollback อัตโนมัติ |
| จำนวน request ไป canary ในขั้นนี้ | `MIN_SAMPLES=20` | ต้องครบก่อน advance (ยกเว้นขั้น 0% → 10%) |
| Canary 5xx rate | `MAX_ERROR_RATE=0.05` | เกินเมื่อมี samples ครบ → rollback อัตโนมัติ |
| ขั้นของ rollout | `CANARY_STEPS=0,10,25,50,100` | ต้องเริ่มที่ 0 และจบที่ 100 |
| รอบการวิเคราะห์ | `ANALYSIS_INTERVAL_SECONDS=2` | analysis loop ตรวจทุก 2 วินาทีเมื่อ 0 < w < 100 |

จุดสำคัญของ lab: backend ที่ถูก inject fault ยังตอบ `/healthz` ปกติ health check จึงไม่เห็นปัญหา มีแต่ request metrics จาก Envoy ที่จับได้ ซึ่งเป็นเหตุผลว่าทำไม canary analysis ต้องดู error rate ไม่ใช่แค่ liveness

API ป้องกันการกดซ้อนด้วย `expected_weight`: ถ้าหน้าจอเก่าส่ง weight ที่ไม่ตรงกับที่ Envoy ใช้อยู่จะได้ HTTP 409

## รัน smoke test

PowerShell:

```powershell
pwsh -NoProfile -File ./test.ps1
```

Linux/macOS/Git Bash:

```sh
sh ./test.sh
```

Test ตรวจว่า:

1. เริ่มที่ 0% ตอบ `VERSION-1`; advance เป็น 10% แล้ว 200 requests แบ่งไป canary ประมาณ 10% และ header `x-canary: always` ได้ `VERSION-2` เสมอ
2. `expected_weight` ที่ไม่ตรงถูกปฏิเสธด้วย 409
3. Inject 5xx 100% ที่ canary → controller rollback เป็น 0% เอง สถานะ `rolled_back` และมี event `auto_rollback`
4. Advance โดยยังไม่มี samples ถูก block ด้วย 409
5. Canary ปกติ → advance ทีละขั้นจนถึง 100% สถานะ `promoted` และตอบ `VERSION-2`
6. RDS ที่ schema ผิดถูก reject, traffic ยังใช้ route ล่าสุด และ Envoy container ID ไม่เปลี่ยนตลอด test

ผลสำเร็จขึ้นต้นด้วย `PASS: canary 10% split`

## ทดลองด้วยตนเอง

```sh
sh ./reset.sh
docker compose up -d
# เปิด http://127.0.0.1:8080/deployment/ แล้วกด Advance to 10%
```

สร้าง traffic ในอีก terminal:

```sh
while true; do curl -s http://127.0.0.1:8080/; sleep 0.1; done
```

เพิ่มขั้นผ่าน API แทน UI ได้:

```sh
curl -H 'Content-Type: application/json' \
  -d '{"action":"advance","expected_weight":10}' \
  http://127.0.0.1:8080/deployment/api/rollout
```

จำลอง release เสีย (30% ของ request ตอบ 500) แล้วดู Console rollback เอง:

```sh
docker compose exec backend-canary python -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:9000/fault?rate=0.3', method='POST'))"
```

คืนค่าปกติด้วย `rate=0` แล้วเริ่ม rollout ใหม่ได้ Rollback แบบ manual ใช้ `{"action":"rollback","expected_weight":<w>}` หรือปุ่ม `Rollback to 0%`

ดูสิ่งที่ Envoy ใช้จริง:

```sh
curl http://127.0.0.1:9901/config_dump?resource=dynamic_route_configs
curl "http://127.0.0.1:9901/stats?filter=cluster\.backend_(stable|canary)\.upstream_rq_(completed|5xx)"
docker compose logs deployment-ui
```

## แก้ปัญหา

- ปุ่ม Advance กดไม่ได้: ดู Analysis gate ส่วนใหญ่คือ samples ยังไม่ครบ ให้ส่ง traffic เพิ่มหรือใช้ header `x-canary: always`
- Rollback ทันทีหลัง advance: canary ยังมี fault อยู่ ตรวจด้วย `docker compose exec backend-canary python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9000/').read())"`
- เริ่มใหม่แล้ว weight ไม่ใช่ 0%: controller adopt ค่าที่ Envoy ใช้อยู่เสมอ ให้รัน `./reset.sh` ก่อน `docker compose up`

## Cleanup

```sh
sh ./reset.sh
docker compose down -v
```
