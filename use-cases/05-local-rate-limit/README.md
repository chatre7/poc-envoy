# 05 — Local Rate Limit

## เป้าหมาย

พิสูจน์การจำกัด request แบบ token bucket ภายใน Envoy process: รับ burst ได้ 2 requests จากนั้นคืน 429 จนกว่า token จะเติมใหม่

## สถาปัตยกรรมและไฟล์

```text
Client -> Envoy local_ratelimit -> Backend OK
             | token หมด
             +------------------> 429
```

Compose รัน Envoy กับ echo backend, `envoy.yaml` วาง local-rate-limit filter ก่อน router และ test scripts ตรวจ burst/header/refill

> รันทีละ lab บนพอร์ต 8080/9901 ค่า 2 requests ต่อ 5 วินาทีต่ำโดยเจตนา

## เริ่มและทดลอง

```powershell
docker compose up -d
1..5 | ForEach-Object { curl.exe -i http://127.0.0.1:8080/ }
```

สองครั้งแรกควรได้ 200 จากนั้นได้ 429 พร้อม `x-local-rate-limit: true` รอ 5 วินาทีแล้ว request ใหม่จะผ่าน

Local rate limit มี bucket ต่อ Envoy process จึงไม่รับประกัน quota รวมเมื่อมีหลาย replicas ต่างจาก global rate limit ที่ประสานผ่าน rate-limit service

## Smoke test และ expected output

```powershell
./test.ps1
```

หรือ `./test.sh` ผลสำเร็จคือ `PASS: local token bucket limited burst and refilled`

## Stats

```powershell
(Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=http_local_rate_limit' -UseBasicParsing).Content
```

ดู counters `enabled`, `ok` และ `rate_limited`

## แก้ปัญหา

- request แรกได้ 429: restart Envoy เพื่อล้าง bucket หรือรอ refill
- ไม่มี header: ดู `docker compose logs envoy` และลำดับ filters
- Backend ไม่ตอบ: ดู `docker compose logs backend`
- พอร์ตชน: ปิด lab อื่นก่อน
- ดึง image ไม่ได้: ตรวจ Docker network/proxy

## Cleanup

```powershell
docker compose down -v
```
