# Demo JWT fixtures

ไฟล์นี้เป็น token สาธิตแบบ RS256 ที่ไม่มี `exp` เพื่อให้ lab ทำซ้ำได้:

- `authorized.token`: claim `role=admin`
- `unauthorized.token`: claim `role=viewer`
- `jwks.json`: public key ที่ Envoy ใช้ตรวจ signature

Private key ถูกทิ้งหลังสร้าง fixture ชุดนี้ Token ไม่มีวันหมดอายุและไม่ใช่ credential จริง ห้ามนำ key, issuer หรือแนวทางนี้ไปใช้ production
