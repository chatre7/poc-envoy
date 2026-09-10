# 11 — Blue/Green Deployment UI

Lab นี้ต่อยอด Dynamic xDS เป็น workflow สำหรับผู้ดูแลระบบ: Nginx รับ traffic หน้าเครื่อง, Envoy เลือก Blue/Green backend และ Release Console ใช้ตรวจสุขภาพ, Promote และ Rollback โดยไม่ restart proxy

## สถาปัตยกรรม

```text
Client :8080 -> Nginx -> Envoy :10000 -> Blue  backend-v1
                    \-> Release Console       \-> Green backend-v2
Admin :9901 ---------------------> Envoy
```

`envoy.yaml` เป็น bootstrap, `xds/clusters.yaml` เป็น CDS, `xds/routes-current.yaml` เป็น RDS ที่ใช้งานจริง และ `deployment-ui/` มีหน้าเว็บกับ Python controller

> Nginx และ Envoy Admin bind ที่ `127.0.0.1` เท่านั้น UI ไม่มีระบบบัญชีและออกแบบสำหรับ local operator lab ห้ามเปิด port สู่ public network

## Release Console

เปิด `http://127.0.0.1:8080/deployment/` หลังเริ่ม Compose หน้า UI แสดง active route, RDS revision, health probe ของ Blue/Green และเงื่อนไขก่อนเปลี่ยน traffic

- เมื่อ Blue active ปุ่ม `Promote Green` จะตรวจ Green แล้ว publish `routes-v2.yaml`
- เมื่อ Green active ปุ่ม `Rollback to Blue` จะ publish `routes-v1.yaml`
- Controller ใช้ expected-active guard ป้องกันหน้าจอเก่าสลับทับสถานะใหม่
- ทุก update เขียน temporary file, `fsync` และ atomic rename ก่อนรอ `config_dump` ยืนยัน
- ถ้า Envoy ไม่ยอมรับ update ภายในเวลาที่กำหนด controller จะคืน route เดิม

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

1. เริ่มต้นตอบ `VERSION-1` และ UI API รายงาน Blue active
2. Promote Green ผ่าน Release Console แล้วตอบ `VERSION-2` โดย Envoy container ID เดิม
3. ส่ง resource ที่ schema ผิด จากนั้น Envoy ยังใช้ config ล่าสุดที่ยอมรับและเพิ่ม counter `update_rejected`
4. Rollback ผ่าน Release Console แล้วกลับมาตอบ `VERSION-1`

## ทดลองด้วยตนเอง

```powershell
./reset.ps1
docker compose -f ./docker-compose.yml up -d
Start-Process http://127.0.0.1:8080/deployment/
$body = @{ target = 'green'; expected_active = 'blue' } | ConvertTo-Json -Compress
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/deployment/api/switch -ContentType application/json -Body $body
curl.exe http://127.0.0.1:8080/
```

ดู config ที่ Envoy ยอมรับจริงและสถิติการอัปเดต:

```powershell
curl.exe http://127.0.0.1:9901/config_dump
curl.exe "http://127.0.0.1:9901/stats?filter=update_(success|rejected)"
```

ถ้า route ไม่เปลี่ยน ให้ดูสถานะ candidate ใน Release Console และ `docker compose logs deployment-ui envoy nginx` หากเริ่มใหม่แล้วได้ version ผิด ให้รัน `./reset.ps1`

## Cleanup

```powershell
./reset.ps1
docker compose -f ./docker-compose.yml down -v
```
