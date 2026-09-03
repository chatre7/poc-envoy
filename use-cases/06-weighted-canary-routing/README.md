# 06 — Weighted Canary Routing

## เป้าหมาย

พิสูจน์การแบ่ง traffic 80% ไป stable และ 20% ไป canary พร้อม route override แบบกำหนดผลได้ด้วย header

## สถาปัตยกรรมและไฟล์

```text
default request ----------> Envoy --80--> STABLE
                                  \-20--> CANARY
x-canary: always ---------> Envoy ------> CANARY
```

Compose สร้างสอง clusters, `envoy.yaml` เรียง header route ก่อน weighted fallback และ scripts ตรวจทั้ง distribution กับ override

> รันทีละ lab บน 8080/9901 สัดส่วนเป็นความน่าจะเป็น ไม่ใช่การรับประกันว่าทุก 10 requests ต้องเป็น 8/2 พอดี

## เริ่มและทดลอง

```powershell
docker compose up -d
1..20 | ForEach-Object { curl.exe -s http://127.0.0.1:8080/ }
curl.exe -H "x-canary: always" http://127.0.0.1:8080/
```

ชุดแรกเห็น STABLE มากกว่า CANARY ส่วนคำสั่งที่มี header ต้องได้ `CANARY` เสมอ Route order สำคัญ: กฎเฉพาะต้องอยู่ก่อน catch-all

## Smoke test และ expected output

```powershell
./test.ps1
```

หรือ `./test.sh` ตัว test ใช้ 100 samples และ tolerance กว้างเพื่อลด flaky result ผลสำเร็จขึ้นต้น `PASS: weighted stable=`

## Stats

```powershell
(Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=cluster\.(stable|canary).*upstream_rq_total' -UseBasicParsing).Content
```

## แก้ปัญหา

- ไม่พบ CANARY ใน sample เล็ก: เพิ่มจำนวน requests หรือใช้ smoke test
- Header ไม่ override: ตรวจชื่อ/value และดู `docker compose logs envoy`
- Cluster ตอบ 503: ดู `docker compose logs stable canary`
- พอร์ตชนหรือดึง image ไม่ได้: ปิด lab อื่นและตรวจ Docker network/proxy

## Cleanup

```powershell
docker compose down -v
```
