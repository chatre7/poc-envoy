# 03 — Circuit Breaker

## เป้าหมาย

พิสูจน์ว่า Envoy จำกัดงานพร้อมกันและตอบกลับเร็วเมื่อ upstream เต็ม แทนการปล่อย request สะสมจนระบบล้มตามกัน

## สถาปัตยกรรมและไฟล์

```text
8 concurrent requests -> Envoy (limits ต่ำ) -> /hold รอ 4 วินาที
                           |
                           +-> overflow stats :9901
```

`backend.py` ทำให้ `/hold` ช้าแบบกำหนดได้, `envoy.yaml` ตั้ง circuit breaker ต่ำโดยเจตนา, Compose เชื่อม services และ test scripts สร้าง concurrent load

> รันทีละ lab บนพอร์ต 8080/9901 ค่า limits นี้เล็กเกิน production และมีไว้เพื่อให้เห็นผลภายในเครื่องเดียว

## เริ่มและทดลอง

```powershell
docker compose up -d
./test.ps1
```

test ส่ง 8 requests พร้อมกัน ควรมีทั้ง 200 จากงานที่รับได้และ 503 จากงานที่เกิน limit โดย 503 จาก Envoy มักมี `x-envoy-overloaded` จึงแยกจาก application error ได้

## Stats

```powershell
(Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=upstream_rq_.*overflow' -UseBasicParsing).Content
```

ดู `upstream_rq_pending_overflow` หรือ `upstream_rq_active_overflow` Circuit breaker ของ Envoy เป็น distributed/local ต่อ proxy instance ไม่ใช่ global quota

## Expected output

`PASS: circuit breaker returned 200 and 503; overflow counter increased`

POSIX ใช้ `./test.sh`

## แก้ปัญหา

- ไม่มี 503: ตรวจว่า test ส่งพร้อมกันและดู `docker compose logs backend`
- ทุก request ล้ม: รอ `/health` ให้พร้อมและดู `docker compose logs envoy`
- พอร์ตชน: ปิด lab อื่นที่ใช้ 8080/9901
- ดึง image ไม่ได้: ตรวจ Docker proxy/network และใช้ `docker compose pull`

## Cleanup

```powershell
docker compose down -v
```
