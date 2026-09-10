# Envoy Use-Case Lab

Repository นี้มีสองส่วน: POC เดิมแบบ `Nginx → Envoy → APP-1/APP-2` ที่ root และชุด lab แยกตาม use case จำนวน 12 ตัว แต่ละ lab มี topology, config, คู่มือภาษาไทย และ smoke test ของตัวเอง

> Lab ทุกตัวใช้ host ports `8080` และ `9901` เหมือนกัน จึงต้องรันทีละตัวและปิดตัวเดิมด้วย `docker compose down -v` ก่อนเริ่มตัวถัดไป Envoy Admin เปิดไว้เพื่อการเรียนรู้เฉพาะเครื่อง local เท่านั้น

## สิ่งที่ต้องมี

| เครื่องมือ | ใช้ทำอะไร |
|---|---|
| Docker Desktop / Docker Engine + Compose v2 | รัน Envoy และ service ประกอบ |
| PowerShell 7+ หรือ POSIX shell | รัน smoke test |
| curl | ส่ง HTTP request |
| OpenSSL | สร้าง certificate และทดสอบ lab 07 |

ชุดตัวอย่างใหม่ pin Envoy ที่ `envoyproxy/envoy:v1.32.13`; image อื่น ๆ ระบุ version ชัดเจนใน Compose ของแต่ละ lab

## เส้นทางการเรียนรู้

| ลำดับ | Use case | สิ่งที่พิสูจน์ | ระดับ |
|---:|---|---|---|
| 01 | [Load balancing + health check](use-cases/01-load-balancing-health-check/) | Round robin, active probe, removal และ recovery | เริ่มต้น |
| 02 | [Retry + timeout](use-cases/02-retry-timeout/) | 5xx retry, per-try timeout และ overall timeout | เริ่มต้น |
| 03 | [Circuit breaker](use-cases/03-circuit-breaker/) | จำกัด concurrent/pending work และ overflow | กลาง |
| 04 | [Outlier detection](use-cases/04-outlier-detection/) | Passive ejection จากผลลัพธ์จริง | กลาง |
| 05 | [Local rate limit](use-cases/05-local-rate-limit/) | Token bucket, HTTP 429 และ refill | เริ่มต้น |
| 06 | [Weighted canary routing](use-cases/06-weighted-canary-routing/) | กระจาย 80/20 และ header override | กลาง |
| 07 | [TLS + mTLS](use-cases/07-tls-mtls/) | TLS termination และ client certificate trust | กลาง |
| 08 | [Observability](use-cases/08-observability/) | JSON logs, Prometheus metrics และ Jaeger traces | กลาง |
| 09 | [JWT + RBAC](use-cases/09-jwt-rbac/) | แยก authentication 401 จาก authorization 403 | สูง |
| 10 | [Dynamic xDS](use-cases/10-dynamic-xds/) | เปลี่ยน RDS โดยไม่ restart และ reject config ผิด | สูง |
| 11 | [Blue/Green Deployment UI](use-cases/11-blue-green-deployment-ui/) | Promote/Rollback ผ่าน Nginx และ Release Console | สูง |
| 12 | [Production Blue/Green Stack](use-cases/12-production-blue-green-stack/) | Failover detection, Prometheus alerts, Alertmanager lifecycle, Grafana และ guarded traffic switch | สูง |

## วิธีรัน lab

PowerShell:

```powershell
Set-Location use-cases/01-load-balancing-health-check
docker compose -f ./docker-compose.yml up -d
./test.ps1
docker compose -f ./docker-compose.yml down -v
```

Linux/macOS/Git Bash:

```sh
cd use-cases/01-load-balancing-health-check
docker compose -f ./docker-compose.yml up -d
sh ./test.sh
docker compose -f ./docker-compose.yml down -v
```

Smoke test แต่ละตัวจัดการ start/cleanup เอง ดังนั้นโดยปกติเรียกเพียง `./test.ps1` หรือ `sh ./test.sh` ก็พอ

ตรวจ config ทั้ง repository โดยไม่รัน traffic test:

```powershell
pwsh -NoProfile -File ./scripts/validate.ps1
```

รัน acceptance suite เต็ม:

```powershell
pwsh -NoProfile -File ./scripts/validate.ps1 -Runtime
```

ฝั่ง POSIX ใช้ `sh ./scripts/validate.sh` หรือเพิ่ม `--runtime`

## Lab 12: Production Failover Monitoring

Lab สุดท้ายรวมเส้นทาง production ไว้ใน Compose stack เดียว:

```text
Client :8080 -> Nginx -> Envoy -> Blue / Green backends
                         |
Release Controller metrics -> Prometheus -> Alertmanager
                                  |              |
                                  v              v
                               Grafana     webhook audit
Envoy traces -----------------> Jaeger
```

เริ่มระบบ:

```powershell
Set-Location use-cases/12-production-blue-green-stack
./reset.ps1
docker compose up -d
```

| Operator surface | URL |
|---|---|
| Release Console | http://127.0.0.1:8080/deployment/ |
| Grafana | http://127.0.0.1:3000/d/envoy-production/envoy-production-and-failover |
| Prometheus | http://127.0.0.1:9090 |
| Alertmanager | http://127.0.0.1:9093 |
| Jaeger | http://127.0.0.1:16686 |

ทดลอง incident โดยหยุด active Blue:

```powershell
docker compose stop backend-v1
```

Release Console จะรายงาน `Failover Required`, Prometheus เปลี่ยน `ActiveReleaseUnhealthy` จาก Pending เป็น Firing และ Alertmanager ส่ง webhook เข้า controller จากนั้น operator จึงสั่ง `Fail over to Green` แบบ guarded switch ระบบไม่สลับ traffic อัตโนมัติจาก probe failure เพียงครั้งเดียว

รัน drill เต็มซึ่งตรวจ `Pending -> Firing -> Resolved`, webhook, recovery, xDS rejection safety และ rollback:

```powershell
pwsh -NoProfile -File ./test.ps1
```

ทุก port bind ที่ `127.0.0.1`; webhook receiver ใช้ได้เฉพาะ Compose network และ public path `/deployment/api/alerts` ถูก Nginx ปิดไว้ รายละเอียด metrics และ alert ทั้งหมดอยู่ใน [คู่มือ Lab 12](use-cases/12-production-blue-green-stack/)

## POC เดิม: Nginx → Envoy

ไฟล์ root `docker-compose.yml`, `nginx.conf` และ `envoy.yaml` ยังทำงานแบบเดิมเพื่อรักษา quick start เดิม:

```bash
docker compose up -d
```

ทดสอบ load balancing:

```bash
for i in {1..10}; do curl -s http://127.0.0.1:8080; echo; done
```

ควรพบทั้ง `Hello from APP-1` และ `Hello from APP-2` เปิด Envoy Admin ได้ที่ `http://127.0.0.1:9901` และดูข้อมูลด้วย:

```bash
curl http://127.0.0.1:9901/stats
curl http://127.0.0.1:9901/clusters
```

ทดลอง failure/health checking:

```bash
docker compose stop app1
# รอประมาณ 10 วินาทีแล้วส่ง request ซ้ำ
docker compose start app1
```

ปิด POC:

```bash
docker compose down -v
```
