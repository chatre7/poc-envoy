# 09 — JWT Authentication และ RBAC

## เป้าหมาย

แยก authentication ออกจาก authorization: Envoy ตรวจ JWT signature/issuer/audience ก่อน แล้ว RBAC อนุญาตเฉพาะ claim `role=admin`

## สถาปัตยกรรมและไฟล์

```text
Request -> jwt_authn -> RBAC -> router -> AUTHORIZED
             401        403
```

`fixtures/` มี public JWKS และสอง tokens, `envoy.yaml` เรียง JWT → RBAC → router, Compose รัน protected backend และ scripts ตรวจ status matrix

> Fixtures ไม่มีวันหมดอายุและมีไว้เพื่อ demo เท่านั้น ห้ามใช้เป็น credential จริง รันทีละ lab บน 8080/9901

## เริ่มและทดลอง

```powershell
docker compose up -d
$admin = (Get-Content -Raw fixtures/authorized.token).Trim()
curl.exe -i -H "Authorization: Bearer $admin" http://127.0.0.1:8080/
```

- ไม่มี token หรือ token เสีย: 401 จาก `jwt_authn`
- token ถูกต้องแต่ `role=viewer`: 403 จาก RBAC
- token ถูกต้องและ `role=admin`: 200 `AUTHORIZED`

Filter order สำคัญ เพราะ RBAC อ่าน claim `payload.role` จาก dynamic metadata ที่ JWT filter สร้าง

## Smoke test และ expected output

```powershell
./test.ps1
```

หรือ `./test.sh` ผลสำเร็จคือ `PASS: JWT authentication returned 401; RBAC returned 403/200 by role`

## Stats

```powershell
(Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=(jwt_authn|rbac)' -UseBasicParsing).Content
```

## แก้ปัญหา

- ทุก token ได้ 401: ตรวจ issuer/audience/kid และดู `docker compose logs envoy`
- admin ได้ 403: ตรวจ metadata path กับ claim `role`
- Backend ไม่ตอบหลังผ่าน auth: ดู `docker compose logs backend`
- พอร์ตชนหรือดึง image ไม่ได้: ปิด lab อื่นและตรวจ Docker network/proxy

Production ควรใช้ IdP, remote JWKS ผ่าน TLS, token expiration, key rotation และนโยบาย claim ที่องค์กรกำหนด

## Cleanup

```powershell
docker compose down -v
```
