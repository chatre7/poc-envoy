# 07 — TLS และ Mutual TLS

## เป้าหมาย

พิสูจน์ TLS termination และการบังคับ client certificate: เฉพาะ client ที่ออกโดย CA ที่ Envoy เชื่อถือจึงเข้าถึง backend ได้

## สถาปัตยกรรมและไฟล์

```text
Client certificate -> TLS/mTLS -> Envoy :8080 -> HTTP backend
                                  Admin :9901 (HTTP เฉพาะ lab)
```

`generate-certs.ps1`/`.sh` สร้าง CA และ certificates อายุ 1 วัน, `envoy.yaml` ตั้ง DownstreamTlsContext, Compose mount `certs/` แบบ read-only และ tests ตรวจสี่กรณี handshake

> Keys ทั้งหมดเป็น local fixtures สำหรับการเรียนรู้ สร้างใหม่ทุกครั้งและถูก ignore ห้ามนำไปใช้จริง รันทีละ lab เพราะใช้ 8080/9901

## สร้าง certificate และเริ่มระบบ

```powershell
./generate-certs.ps1
docker compose up -d
"GET / HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n" | openssl s_client -connect 127.0.0.1:8080 -CAfile certs/ca.crt -cert certs/client.crt -key certs/client.key -quiet
```

ผลคือ `mTLS OK` ส่วน request แบบ HTTP, ไม่มี client cert หรือใช้ `untrusted-client.crt` ต้อง handshake ไม่สำเร็จ

CA สร้าง trust anchor, server cert ยืนยัน Envoy และ client cert ยืนยัน caller ค่า SAN รองรับทั้ง `localhost` และ `127.0.0.1` Generator สร้างทั้ง PEM และ PKCS#12; คู่มือใช้ `openssl s_client` เพื่อไม่ขึ้นกับ Windows certificate store

## Smoke test และ expected output

```powershell
./test.ps1
```

หรือ `./test.sh` ผลสำเร็จขึ้นต้น `PASS: plaintext, missing, and untrusted clients rejected`

## Stats

```powershell
(Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=ssl' -UseBasicParsing).Content
```

ดู handshake, connection error และ certificate counters ภายใต้ listener

## แก้ปัญหา

- ไม่มี `openssl`: ติดตั้ง OpenSSL 3.x แล้วตรวจด้วย `openssl version`
- Envoy หา cert ไม่พบ: รัน generator ก่อนและดู `docker compose logs envoy`
- Certificate หมดอายุ: generator สร้างใหม่ได้ทันที
- พอร์ตชนหรือดึง image ไม่ได้: ปิด lab อื่นและตรวจ Docker network/proxy

## Cleanup

```powershell
docker compose down -v
```

ไฟล์ใน `certs/` ลบได้และสร้างใหม่ได้เสมอ
