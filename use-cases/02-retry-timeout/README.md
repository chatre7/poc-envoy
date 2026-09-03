# 02 — Retry และ Timeout

## เป้าหมาย

พิสูจน์ retry เมื่อ backend คืน 503 หรือใช้เวลานานกว่า `per_try_timeout` และพิสูจน์ว่า `timeout` รวมยังจำกัดเวลาของ request ทั้งหมด

## สถาปัตยกรรม

```text
Client :8080 -> Envoy -> Python backend
                    retry 1 ครั้ง
Admin :9901 -----> retry counters
```

`backend.py` มี endpoint ที่ตอบแบบกำหนดผลได้, `envoy.yaml` กำหนด retry/timeout และ test scripts ตรวจทั้ง response header กับ stats จึงไม่สับสนกับ health-check failover

> ให้รันทีละ lab เพราะใช้พอร์ต 8080/9901 ร่วมกัน ค่า timeout และ retry นี้สร้างเพื่อการเรียนรู้ ไม่ใช่ค่าที่แนะนำสำหรับทุกระบบ

## เริ่มและทดลอง

```powershell
docker compose up -d
curl.exe -i http://localhost:8080/fail-once
curl.exe -i http://localhost:8080/slow-once
curl.exe -i http://localhost:8080/always-slow
```

- `/fail-once`: attempt แรกคืน 503; Envoy retry แล้วคืน 200 พร้อม `x-backend-attempt: 2`
- `/slow-once`: attempt แรกช้ากว่า 2 วินาที; attempt ที่สองคืน 200
- `/always-slow`: ทุก attempt ช้าเกินกำหนด; client ได้ 504 ภายในประมาณ 5 วินาที

`per_try_timeout: 2s` จำกัดแต่ละ attempt ส่วน `timeout: 5s` ครอบ request ทั้งหมด การ retry operation ที่ไม่ idempotent อาจทำงานซ้ำและต้องออกแบบอย่างระมัดระวัง

## Smoke test

```powershell
./test.ps1
```

```bash
./test.sh
```

ผลสำเร็จคือ `PASS: 5xx retry, per-try timeout, and overall timeout verified`

## Stats ที่ควรดู

```powershell
(Invoke-WebRequest 'http://localhost:9901/stats?filter=upstream_rq_retry' -UseBasicParsing).Content
```

ดู `cluster.backend_cluster.upstream_rq_retry` และ `upstream_rq_retry_success` การ retry จำนวนมากสามารถขยาย traffic จนเกิด retry storm จึงควรใช้ retry budget/limits ใน production

## แก้ปัญหา

- ได้ 503 โดยไม่ retry: ดู `docker compose logs envoy` และตรวจ retry policy
- Header attempt ไม่ใช่ 2: restart backend เพื่อล้าง counter ด้วย `docker compose restart backend`
- พอร์ตชน: หยุด lab อื่นด้วย `docker compose down -v`
- Backend ไม่ตอบ: ดู `docker compose logs backend`
- ดาวน์โหลด image ไม่ได้: ตรวจ Docker network/proxy แล้วรัน `docker compose pull`

## Cleanup

```powershell
docker compose down -v
```
