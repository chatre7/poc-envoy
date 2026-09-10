# 10 — Dynamic xDS (filesystem)

ตัวอย่างนี้แยก bootstrap แบบ static ออกจาก resource ที่เปลี่ยนขณะ Envoy ทำงาน โดยโหลด CDS และ RDS ผ่าน filesystem subscription แล้วสลับ route จาก backend v1 ไป v2 โดยไม่ restart container

สถาปัตยกรรมคือ `Client :8080 → Envoy → backend-v1/backend-v2`; `envoy.yaml` เป็น bootstrap, `xds/clusters.yaml` เป็น CDS, `xds/routes-*.yaml` เป็น RDS fixtures, `reset.*` คืนค่า v1 และ `test.*` พิสูจน์ update/rejection ครบวงจร

> รันทีละ lab เพราะใช้พอร์ต 8080/9901 ร่วมกับ lab อื่น และอย่าเปิด Admin interface สู่ public network

## สิ่งที่เรียนรู้

- **LDS** ควบคุม listener และ network filter chain
- Lab นี้ทำ listener เป็น static เพื่อให้เห็นขอบเขต bootstrap ชัดเจน
- **CDS** โหลด `backend_v1` และ `backend_v2` จาก `xds/clusters.yaml`
- **RDS** โหลด route ชื่อ `dynamic_route` จาก `xds/routes-current.yaml`
- filesystem xDS เป็นตัวอย่างสำหรับเรียนรู้ lifecycle ของ update; production มักใช้ xDS control plane ผ่าน gRPC เพื่อ ACK/NACK, versioning และ rollout ที่ควบคุมได้
- การเขียนไฟล์ต้องใช้ atomic rename ภายใน container เพื่อให้ Envoy รับ filesystem notification อย่างสม่ำเสมอบน Docker Desktop

## รัน

PowerShell:

```powershell
pwsh -NoProfile -File ./test.ps1
```

Linux/macOS/Git Bash:

```sh
sh ./test.sh
```

Smoke test จะตรวจว่า:

1. เริ่มต้นตอบ `VERSION-1`
2. เปลี่ยน `routes-current.yaml` เป็น version 2 แล้วตอบ `VERSION-2` โดย container ID เดิม
3. ส่ง resource ที่ schema ผิด จากนั้น Envoy ยังใช้ config ล่าสุดที่ยอมรับและเพิ่ม counter `update_rejected`

## ทดลองด้วยตนเอง

```powershell
./reset.ps1
docker compose -f ./docker-compose.yml up -d
curl.exe http://127.0.0.1:8080/
docker compose -f ./docker-compose.yml exec -T envoy sh -c "cp /etc/envoy/xds/routes-v2.yaml /etc/envoy/xds/routes-current.yaml.tmp && mv /etc/envoy/xds/routes-current.yaml.tmp /etc/envoy/xds/routes-current.yaml"
curl.exe http://127.0.0.1:8080/
```

ดู config ที่ Envoy ยอมรับจริงและสถิติการอัปเดต:

```powershell
curl.exe http://127.0.0.1:9901/config_dump
curl.exe "http://127.0.0.1:9901/stats?filter=update_(success|rejected)"
```

ถ้า route ไม่เปลี่ยน ให้ตรวจว่าแก้ `routes-current.yaml` ด้วย atomic rename ภายใน container และดู `docker compose logs envoy` เพื่อหา NACK/schema error การ rename จาก Windows host อาจไม่ส่ง file event ผ่าน Docker Desktop หากเริ่มใหม่แล้วได้ version ผิด ให้รัน `./reset.ps1`

หากเริ่ม container ไม่ได้ ให้ตรวจ port conflict ด้วย `docker compose ps`; หาก image ยังไม่มีในเครื่องให้ตรวจ network แล้ว `docker compose pull`

## ปิดระบบ

```powershell
./reset.ps1
docker compose -f ./docker-compose.yml down -v
```
