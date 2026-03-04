# Требуем права администратора
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "=== Настройка автовхода и автозапуска приложения ===" -ForegroundColor Cyan

# 1. Ввод данных учетной записи
$Username = Read-Host "Введите имя пользователя"
$Password = Read-Host "Введите пароль" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

# 2. Настройка реестра для автовхода (Winlogon)
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

try {
    Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value "1" -Force
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultUserName" -Value $Username -Force
    Set-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -Value $PlainPassword -Force
    # Убираем требование Ctrl+Alt+Del (опционально)
    Set-ItemProperty -Path $WinlogonPath -Name "LegalNoticeCaption" -Value "" -Force
    Set-ItemProperty -Path $WinlogonPath -Name "LegalNoticeText" -Value "" -Force
    
    Write-Host "[OK] Параметры автовхода настроены." -ForegroundColor Green
}
catch {
    Write-Host "[ERROR] Не удалось настроить автовход: $_" -ForegroundColor Red
    exit
}

# 3. Настройка автозапуска приложения
$AppPath = "c:\scan\scan.exe"
$RunKeyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
$AppName = "ScanApp"

if (Test-Path $AppPath) {
    try {
        # Добавляем кавычки на случай пробелов в пути, хотя в данном примере их нет
        Set-ItemProperty -Path $RunKeyPath -Name $AppName -Value "`"$AppPath`"" -Force
        Write-Host "[OK] Приложение добавлено в автозагрузку." -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Не удалось добавить приложение в автозагрузку: $_" -ForegroundColor Red
    }
}
else {
    Write-Host "[WARNING] Файл $AppPath не найден. Автозапуск не настроен." -ForegroundColor Yellow
}

Write-Host "`nДля применения настроек необходима перезагрузка." -ForegroundColor Yellow
$restart = Read-Host "Перезагрузить компьютер сейчас? (Y/N)"
if ($restart -eq 'Y' -or $restart -eq 'y') {
    Restart-Computer -Force
}
