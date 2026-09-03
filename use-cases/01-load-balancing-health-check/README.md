# 01 — Load Balancing และ Active Health Check

## เป้าหมาย

พิสูจน์ว่า Envoy กระจาย request แบบ Round Robin ไปยังสอง backend และหยุดส่ง traffic ไปยัง backend ที่ active health check ตรวจพบว่าล่ม ก่อนนำกลับเข้ากลุ่มเมื่อฟื้นตัว

## สถาปัตยกรรม

```text
Client :8080 -> Envoy :10000 -> APP-1 :8080
                            \-> APP-2 :8080
Admin :9901 ----------------> Envoy
```

ไฟล์ `docker-compose.yml` สร้างสาม services บน network เดียวกัน, `envoy.yaml` กำหนด listener/cluster/health check และ `test.ps1`/`test.sh` ตรวจพฤติกรรมครบวงจร

> ทุก lab ใช้พอร์ต 8080 และ 9901 เหมือนกัน ให้หยุด lab ก่อนหน้าก่อนเริ่มตัวนี้ หน้า Admin เปิดสำหรับเครื่องทดลองเท่านั้นและไม่ควรเปิดสู่เครือข่าย production

## เริ่มระบบ

```powershell
docker compose up -d
1..10 | ForEach-Object { (Invoke-WebRequest http://localhost:8080 -UseBasicParsing).Content }
```

ผลควรสลับระหว่าง `Hello from APP-1` และ `Hello from APP-2`

## ทดลอง health check ด้วยตนเอง

```powershell
docker compose pause app1
Start-Sleep 5
1..6 | ForEach-Object { (Invoke-WebRequest http://localhost:8080 -UseBasicParsing).Content }
```

หลังรอประมาณ 4–5 วินาที ทุกคำตอบควรมาจาก APP-2 จากนั้นให้คืน APP-1:

```powershell
docker compose unpause app1
```

`pause` จำลอง backend ค้างโดยยังคง IP และ Docker DNS ไว้ จึงแยกผลของ active health check ออกจาก DNS service discovery ได้ชัดเจน `no_traffic_interval` ถูกตั้งเป็น 2 วินาทีเพื่อไม่ใช้ค่าเริ่มต้น 60 วินาทีของ Envoy ส่วน `healthy_threshold: 1` ทำให้ APP-1 กลับมาเมื่อ health check สำเร็จหนึ่งครั้ง Active health check ต่างจาก Outlier Detection ตรงที่ Envoyยิง probe `/` ตามรอบ แม้ไม่มี user traffic

## Smoke test

```powershell
./test.ps1
```

หรือบน POSIX shell:

```bash
./test.sh
```

ผลสำเร็จคือ `PASS: round robin, unhealthy removal, and recovery verified`

## Stats ที่ควรดู

```powershell
Invoke-WebRequest 'http://localhost:9901/stats?filter=health_check' -UseBasicParsing | Select-Object -Expand Content
Invoke-WebRequest http://localhost:9901/clusters -UseBasicParsing | Select-Object -Expand Content
```

สังเกต `cluster.backend_cluster.health_check.*` และ health flags ของแต่ละ host

## แก้ปัญหา

- พอร์ตชน: ตรวจด้วย `docker compose ps` และหยุด lab อื่นที่ใช้ 8080/9901
- Envoy ยังไม่พร้อม: ดู `docker compose logs envoy`
- Backend ไม่ผ่าน health check: ดู `docker compose logs app1 app2`
- ดาวน์โหลด image ไม่ได้: ตรวจ network/proxy ของ Docker Desktop แล้วรัน `docker compose pull`

## Cleanup

```powershell
docker compose down -v
```
