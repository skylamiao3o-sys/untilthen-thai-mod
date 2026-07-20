# ตรวจว่าไฟล์ .pck ที่ build มา 'สมบูรณ์' ก่อนติดตั้งทับเกม
# กันบั๊ก: build ล้มเหลว (ดิสก์เต็ม/แอนติไวรัสล็อก) เหลือไฟล์ไม่ครบ แล้วติดตั้งทับ → เกมโหลดไม่ได้
# คืน "OK" ถ้า: มี magic GDPC + ขนาด >= 95% ของ pck ต้นฉบับ (โมดpck ต้อง >= base เสมอ)
param([string]$Pck, [string]$Base)
if (-not (Test-Path -LiteralPath $Pck)) { Write-Output "MISSING"; exit }
try {
    $fs = (Get-Item -LiteralPath $Pck).Length
    $bs = (Get-Item -LiteralPath $Base).Length
    $r = [System.IO.File]::OpenRead($Pck)
    $m = New-Object byte[] 4
    [void]$r.Read($m, 0, 4)
    $r.Close()
    # Godot pck magic = 'G','D','P','C' = 71,68,80,67
    $magic = ($m[0] -eq 71 -and $m[1] -eq 68 -and $m[2] -eq 80 -and $m[3] -eq 67)
    if ($magic -and ($fs -ge ($bs * 0.95))) {
        Write-Output "OK"
    } else {
        Write-Output ("BAD size=$fs base=$bs magic=$magic")
    }
} catch {
    Write-Output ("ERR " + $_.Exception.Message)
}
