Until Then - ตัวตรวจ checksum (2026-10-09-r1)

1. บันทึกและปิดเกม Until Then
2. แตก ZIP ทั้งหมดลงโฟลเดอร์ใหม่ก่อน อย่าเปิด BAT จากใน ZIP
3. เปิด CHECK_FILES.bat (ไม่ต้อง Run as administrator)
4. ส่งไฟล์ diagnostic.log ที่เกิดขึ้นในโฟลเดอร์เดียวกันกลับมา

ตัวนี้อ่านไฟล์เกมอย่างเดียว ไม่ติดตั้งม็อด ไม่ย้าย/ลบไฟล์ และไม่สั่งปิด Steam
ตรวจตัวอย่างไฟล์ใน UntilThen.pck และ UntilThen.pck.bak รวมถึง .bak.old ถ้ามี
ระบุว่าตัวติดตั้งจะเลือกไฟล์ไหน พร้อมค่า checksum และตำแหน่งข้อมูลที่อ่านจริง
ตรวจเฉพาะตัวอย่างและ extension_list.cfg ไม่ใช่การตรวจความสมบูรณ์ทั้งเกม
ใช้บัฟเฟอร์ข้อมูลไม่เกิน 1 MB ไม่ต้องสร้างไฟล์เกมขนาด 3 GB ใหม่
diagnostic.log มีพาธเกมและข้อมูลสภาพแวดล้อมของ PowerShell

สำหรับผู้ดูแล: ระบุโฟลเดอร์เองได้ด้วย CHECK_FILES.bat -Game "D:\SteamLibrary\steamapps\common\Until Then"
