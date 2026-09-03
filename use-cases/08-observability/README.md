# 08 — Observability: Logs, Metrics และ Traces

## เป้าหมาย

เชื่อม request เดียวกับ structured access log, Prometheus metric และ distributed trace ใน Jaeger

## สถาปัตยกรรมและไฟล์

```text
Client -> Envoy -> Backend
           |-- JSON access log -> docker logs
           |-- /stats/prometheus <- Prometheus :9090
           \-- Zipkin spans ------> Jaeger :16686
```

`envoy.yaml` เปิด JSON logger และ Zipkin tracer, `prometheus.yml` scrape admin endpoint, Compose รัน telemetry services และ smoke tests ตรวจทั้งสาม signals

> รันทีละ lab พอร์ต 8080/9901 ใช้ร่วมกับ lab อื่น ส่วน 9090/16686 เป็น UI สำหรับ local demo เท่านั้น ห้ามเปิด Envoy Admin หรือ telemetry UI สู่เครือข่ายสาธารณะโดยไม่มีการป้องกัน

## เริ่มและทดลอง

```powershell
docker compose up -d
curl.exe -H "x-request-id: 11111111-1111-4111-8111-111111111111" http://127.0.0.1:8080/
docker compose logs envoy
```

- Prometheus: `http://127.0.0.1:9090`
- Jaeger: `http://127.0.0.1:16686` แล้วเลือก service `envoy`
- Envoy metrics: `http://127.0.0.1:9901/stats/prometheus`

Logs เหมาะกับเหตุการณ์ละเอียด, metrics เหมาะกับแนวโน้ม/alert และ traces แสดงเส้นทาง/latency ของ request การใช้ request/trace ID ช่วย correlation ระหว่าง signals

เมื่อใช้ `x-envoy-force-trace` Envoy จะบันทึก trace-reason bits ลงใน UUID ดังนั้นตัวอย่าง `...-4111-...` จะปรากฏใน access log เป็น `...-9111-...`; ส่วนอื่นของ ID ยังคงเดิม

## Smoke test และ expected output

```powershell
./test.ps1
```

หรือ `./test.sh` ผลสำเร็จคือ `PASS: JSON log, Prometheus metric, and Jaeger trace verified`

## Stats

ดู `envoy_http_downstream_rq_total`, `envoy_cluster_upstream_rq_total` และ tracing counters ผ่าน Prometheus หรือ `/stats`

## แก้ปัญหา

- ไม่มี metric: รอ scrape 2–4 วินาทีและดู `docker compose logs prometheus`
- ไม่มี trace: ดู `docker compose logs envoy jaeger` และส่ง request ใหม่
- JSON log ไม่พบ ID: ใช้ `docker compose logs --no-color envoy`
- UI/พอร์ตชน: ปิด lab อื่นหรือ process ที่ใช้ 9090/16686
- ดึง image ไม่ได้: ตรวจ Docker proxy/network

## Cleanup

```powershell
docker compose down -v
```
