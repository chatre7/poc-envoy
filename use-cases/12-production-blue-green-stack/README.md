# 12 — Production Blue/Green Stack

Final Compose lab สำหรับเครื่องเดียว: Nginx เป็น public entry point, Envoy Proxy เป็น data plane, Release Console ควบคุม Blue/Green ผ่าน Dynamic RDS และ telemetry stack เก็บ metrics, dashboard และ distributed traces

## สถาปัตยกรรม

```text
Client :8080 -> Nginx -> Envoy -> Blue backend-v1
                    |          \-> Green backend-v2
                    \-> Release Console

Envoy + Release Controller metrics -> Prometheus :9090 -> Grafana :3000
Prometheus alert rules -----------> Alertmanager :9093 -> Controller webhook audit
Envoy traces ---------------------> Jaeger :16686
Envoy/Nginx/Controller logs ------> docker compose logs
```

ทุก host port bind ที่ `127.0.0.1` เท่านั้น Lab นี้ไม่มี authentication และไม่ได้ออกแบบให้เปิด UI หรือ Envoy Admin สู่ public network

## สิ่งที่รวมมาให้

- Blue/Green Promote และ Rollback โดยไม่ restart Envoy
- expected-active guard, candidate probe และ rollback เมื่อ Envoy ไม่ยอมรับ route
- filesystem CDS/RDS ที่ publish ด้วย atomic rename
- active health check, retry, circuit breaker และ outlier detection สำหรับทั้งสอง backend
- Nginx และ Envoy structured JSON access logs พร้อม request ID เดียวกัน
- Prometheus scrape `/stats/prometheus` ทุก 2 วินาที
- Grafana datasource และ dashboard provision อัตโนมัติ
- Jaeger รับ Zipkin spans จาก Envoy
- controller metrics สำหรับ active slot, backend health, failover required, standby readiness, switch outcomes และ RDS rejection
- Prometheus rules ตรวจ active release, standby, Envoy, controller, RDS rejection และ no healthy upstream
- Alertmanager ส่งทั้ง Firing และ Resolved เข้า private controller webhook; Nginx ปิด public webhook path
- container restart policy และ health check สำหรับ operator surface

## เริ่มระบบ

PowerShell:

```powershell
Set-Location use-cases/12-production-blue-green-stack
./reset.ps1
docker compose up -d
```

Linux/macOS/Git Bash:

```sh
cd use-cases/12-production-blue-green-stack
./reset.sh
docker compose up -d
```

## URL สำหรับ Operator

| Surface | URL | ใช้ทำอะไร |
|---|---|---|
| Release Console | http://127.0.0.1:8080/deployment/ | Promote, Rollback และดู health/interlocks |
| Application | http://127.0.0.1:8080/ | Traffic ที่ผ่าน Nginx และ Envoy |
| Grafana | http://127.0.0.1:3000/d/envoy-production/envoy-production-overview | Dashboard ภาพรวม Envoy |
| Prometheus | http://127.0.0.1:9090 | Query metrics โดยตรง |
| Jaeger | http://127.0.0.1:16686 | ค้นหา trace ของ service `production-blue-green-stack` |
| Alertmanager | http://127.0.0.1:9093 | ดู alert groups และสถานะ Pending/Firing/Resolved |
| Envoy Admin | http://127.0.0.1:9901 | Debug config, stats และ readiness |

Grafana เปิด anonymous Viewer เฉพาะ local lab และ dashboard `Envoy Production & Failover` ถูก provision ตั้งแต่เริ่ม container

## Workflow การ Failover

Lab นี้ตรวจจับและแจ้งเตือนอัตโนมัติ แต่จงใจให้ operator เป็นผู้สั่ง switch traffic:

1. หยุด active Blue เพื่อจำลอง incident: `docker compose stop backend-v1`
2. Release Console แสดง `failover.required=true`; Prometheus เปลี่ยน `ActiveReleaseUnhealthy` จาก Pending เป็น Firing
3. Alertmanager ส่ง Firing webhook เข้า Release Controller และแสดง alert ที่ `:9093`
4. กด Promote Green หรือเรียก `POST /deployment/api/switch`; traffic กลับมาตอบ `VERSION-2` โดยไม่ restart Envoy
5. Prometheus clear alert และ Alertmanager ส่ง Resolved webhook
6. กู้ Blue ด้วย `docker compose start backend-v1` ก่อน rollback

Failover ไม่ทำอัตโนมัติเพื่อป้องกันการสลับจาก transient probe failure โดยไม่มีการตัดสินใจของ operator

| Alert | เงื่อนไข |
|---|---|
| `ActiveReleaseUnhealthy` | active slot probe ไม่ผ่านต่อเนื่อง 6 วินาที |
| `StandbyReleaseUnavailable` | standby probe ไม่ผ่านต่อเนื่อง 15 วินาที |
| `EnvoyDown` | Prometheus scrape Envoy ไม่ได้ 10 วินาที |
| `ReleaseControllerDown` | Prometheus scrape controller ไม่ได้ 10 วินาที |
| `RdsUpdateRejected` | Envoy ปฏิเสธ RDS update ภายใน 5 นาที |
| `NoHealthyUpstream` | Envoy รายงานการเชื่อมต่อที่ไม่มี healthy upstream |

## Workflow การ Release

1. เปิด Release Console และยืนยันว่า Envoy, candidate และ atomic publication แสดงพร้อม
2. ตรวจ Grafana ว่า error/latency ไม่มีความผิดปกติ
3. กด `Promote Green` และยืนยันใน dialog
4. ตรวจ active route เป็น Green, application ตอบ `VERSION-2` และค้นหา trace ใหม่ใน Jaeger
5. หากผิดปกติ กด `Rollback to Blue`; controller จะ publish revision 1 กลับโดยไม่ restart Envoy

## ตรวจด้วย CLI

```powershell
curl.exe http://127.0.0.1:9901/ready
curl.exe http://127.0.0.1:8080/deployment/api/state
curl.exe http://127.0.0.1:9901/config_dump?resource=dynamic_route_configs
curl.exe http://127.0.0.1:9901/stats/prometheus
curl.exe http://127.0.0.1:8080/deployment/metrics
curl.exe http://127.0.0.1:9090/api/v1/alerts
curl.exe http://127.0.0.1:9093/api/v2/alerts
```

ดู structured logs:

```powershell
docker compose logs -f nginx envoy deployment-ui
```

ส่ง request ที่บังคับเก็บ trace:

```powershell
curl.exe -H "x-request-id: 11111111-1111-4111-8111-111111111111" -H "x-envoy-force-trace: true" http://127.0.0.1:8080/
```

จากนั้นเปิด Jaeger และเลือก service `production-blue-green-stack`

## Full Stack Smoke Test

PowerShell:

```powershell
pwsh -NoProfile -File ./test.ps1
```

POSIX shell:

```sh
./test.sh
```

Smoke test ตรวจ readiness, controller metrics, alert rules, private webhook boundary, JSON correlation log, Grafana dashboard, Jaeger trace และ drill จริงครบ `Pending -> Firing -> Resolved`: หยุด active Blue, ยืนยัน HTTP 503 และ failover signal, switch ไป Green โดย Envoy container ID เดิม, รับ resolved webhook, กู้ Blue, ตรวจ rejection safety แล้ว rollback

## Troubleshooting

- UI ยังขึ้น `Unavailable`: รอ service เริ่มครบแล้วกดรีเฟรช หรือตรวจ `docker compose ps`
- Prometheus ไม่มี metric: ตรวจ target ที่ `http://127.0.0.1:9090/targets` และรอ 2–4 วินาที
- Grafana ไม่มี dashboard: ตรวจ `docker compose logs grafana` และ datasource provisioning
- Jaeger ไม่มี trace: ส่ง request พร้อม `x-envoy-force-trace: true` แล้วเลือก service `production-blue-green-stack`
- Alert ไม่ Firing: ตรวจ rule ที่ `http://127.0.0.1:9090/rules`, target ที่ `/targets` และรอเกิน `for` ของ alert
- Webhook ไม่เข้า Console: ตรวจ `docker compose logs alertmanager deployment-ui`; endpoint ใช้ได้เฉพาะ network ภายในและ `/deployment/api/alerts` ต้องตอบ 404
- Route ไม่เปลี่ยน: ตรวจ `docker compose logs deployment-ui envoy` และ `update_rejected`
- Port ชน: Lab ทั้งหมดใช้ 8080/9901 ร่วมกัน; Lab นี้เพิ่ม 3000/9090/9093/16686

## Cleanup

คืน traffic เป็น Blue ก่อนลบ stack:

```powershell
./reset.ps1
docker compose down -v
```
