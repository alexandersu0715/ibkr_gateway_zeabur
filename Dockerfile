FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

# 設定環境變數：全部統一到 /root 以避開使用者權限問題
ENV IBC_VERSION=3.23.0 \
    IBC_PATH=/opt/ibc \
    TWS_PATH=/root/Jts/ibgateway \
    DISPLAY=:99

# 1. 安裝工具
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-numpy \
    novnc websockify fluxbox xterm wget unzip \
    && rm -rf /var/lib/apt/lists/*

# 2. 安裝 IBC 3.23.0 到系統目錄
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

# 3. 核心修正：將 /home/ibgateway 內的結構完全連結到 /root 下
RUN mkdir -p /root/Jts && \
    ln -s /home/ibgateway/Jts/ibgateway /root/Jts/ibgateway && \
    ln -s /home/ibgateway/Jts/jts.ini.tmpl /root/Jts/jts.ini

WORKDIR /app
COPY . .

# 4. 安裝 Python 套件
RUN pip3 install --no-cache-dir -r requirements.txt --break-system-packages --ignore-installed

# 5. 建立啟動腳本 (針對 .vmoptions 找不到的最終修正)
RUN cat <<'EOF' > /app/custom_entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 初始化與路徑對齊 ---"
mkdir -p /root/ibc /root/Jts/ibgateway
[ -f /app/ibc/config.ini ] && cp /app/ibc/config.ini /root/ibc/config.ini

# 關鍵修正：確保 .vmoptions 能被 IBC 找到
# 將檔案從深層目錄連結到 tws-path 的根目錄
ln -sf /home/ibgateway/Jts/ibgateway/10.43.1a/ibgateway.vmoptions /root/Jts/ibgateway/ibgateway.vmoptions
ln -sf /home/ibgateway/Jts/ibgateway/10.43.1a/ibgateway.vmoptions /root/Jts/ibgateway/tws.vmoptions

echo "--- 2. 注入帳密 ---"
python3 -c "
import os, re
path = '/root/ibc/config.ini'
user = os.getenv('IB_USER', '')
pw = os.getenv('IB_PASS', '')
if os.path.exists(path):
    with open(path, 'r') as f: content = f.read()
    content = re.sub(r'^IBUsername=.*', f'IBUsername={user}', content, flags=re.MULTILINE)
    content = re.sub(r'^IBPassword=.*', f'IBPassword={pw}', content, flags=re.MULTILINE)
    content = re.sub(r'^AcceptIncomingAPIConnections=.*', 'AcceptIncomingAPIConnections=yes', content, flags=re.MULTILINE)
    content = re.sub(r'^IbApiPort=.*', 'IbApiPort=4002', content, flags=re.MULTILINE)
    with open(path, 'w') as f: f.write(content)
"

echo "--- 3. 啟動顯示環境 ---"
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 4. 啟動 IB Gateway ---"
export _JAVA_OPTIONS="-Xmx512M -Xms256M -Djava.awt.headless=false"

# 啟動指令：確保 --tws-path 指向包含 10.43.1a 資料夾的目錄
/opt/ibc/scripts/ibcstart.sh 10.43.1a --gateway \
  --tws-path=/root/Jts/ibgateway \
  --ibc-path=/opt/ibc \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 5. 狀態監控 ---"
(while true; do 
    echo "==== [$(date)] MONITORING ===="
    if ps aux | grep -v grep | grep java > /dev/null; then
        echo "✅ IB Gateway 已成功啟動！"
    else
        echo "❌ IB Gateway 未運行。錯誤詳情："
        [ -f /tmp/ibc_boot.log ] && tail -n 10 /tmp/ibc_boot.log
    fi
    sleep 30
done) &

tail -f /dev/null
EOF