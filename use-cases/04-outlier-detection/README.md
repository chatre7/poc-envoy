# 04 — Outlier Detection

## เป้าหมาย

พิสูจน์ passive health checking: Envoy สังเกตผลจาก user traffic และ eject backend ที่คืน 5xx ต่อเนื่อง แม้ backend นั้นยังเชื่อมต่อได้

## สถาปัตยกรรมและไฟล์

```text
Client -> Envoy -> GOOD (200)
                \-> BAD  (503, ยัง reachable)
```

`backend.py` เลือกโหมดจาก environment, Compose รัน good/bad, `envoy.yaml` ตั้ง `consecutive_5xx: 2` และ scripts ตรวจ counter กับ traffic หลัง ejection

> รันทีละ lab บน 8080/9901 ระยะ eject 10 วินาทีสั้นโดยเจตนาเพื่อการสาธิต

## เริ่มและทดสอบ

```powershell
docker compose up -d
1..8 | ForEach-Object { curl.exe -i http://127.0.0.1:8080/ }
./test.ps1
```

ช่วงแรกเห็นทั้ง 200/`GOOD` และ 503/`BAD` หลัง BAD คืน 5xx ต่อเนื่อง Envoy จะ eject host นั้นและ traffic ถัดไปเป็น `GOOD` เท่านั้น เมื่อครบ `base_ejection_time` host มีโอกาสกลับเข้ากลุ่มและถูกประเมินใหม่

Outlier Detection เป็น passive เพราะใช้ผล request จริง ต่างจาก active health check ที่ยิง probe แยก

## Stats และ expected output

```powershell
(Invoke-WebRequest 'http://127.0.0.1:9901/stats?filter=outlier_detection' -UseBasicParsing).Content
```

ดู `cluster.backend_cluster.outlier_detection.ejections_total` ผล test สำเร็จคือ `PASS: consecutive 5xx caused passive host ejection` และ POSIX ใช้ `./test.sh`

## แก้ปัญหา

- ไม่ eject: ดู `docker compose logs envoy` และยืนยันว่ามี 503 จาก `bad`
- เห็น BAD อีกครั้งภายหลัง: ejection หมดเวลาแล้ว เป็นพฤติกรรมที่ตั้งใจ
- พอร์ตชน: ปิด lab อื่นก่อน
- Backend ไม่พร้อม: ดู `docker compose logs good bad`
- ดึง image ไม่ได้: ตรวจ Docker network/proxy

## Cleanup

```powershell
docker compose down -v
```
