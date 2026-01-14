# 1. 使用您指定的基礎映像檔
FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

# 設定環境變數
ENV IBC_VERSION=3.23.0 \
    IBC_PATH=/opt/ibc \
    TWS_PATH=/home/ibgateway/Jts/ibgateway \
    TWS_SETTINGS_PATH=/home/ibgateway/Jts \
    DISPLAY=:99

# 2. 安裝必要工具
RUN apt-get update && apt-get install -y \
    python3 python3-pip wget unzip procps net-tools \
    novnc websockify fluxbox x11vnc xvfb \
    && rm -rf /var/lib/apt/lists/*

# 3. 安裝 IBC 3.23.0
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

# 4. 安裝 Python 依賴 (請確保您的 requirements.txt 包含 ib-async, loguru)
WORKDIR /app
COPY . .
RUN pip3 install --no-cache-dir -r requirements.txt --break-system-packages --ignore-installed || true

# 5. 建立核心啟動腳本
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 強制路徑與權限同步 ---"
# 給予目錄權限
chmod -R 777 /home/ibgateway

# 物理對齊 vmoptions 檔案，防止 IBC 找不到
ORIGIN_VM="/home/ibgateway/Jts/ibgateway/10.43.1a/ibgateway.vmoptions"
if [ -f "$ORIGIN_VM" ]; then
    cp "$ORIGIN_VM" /home/ibgateway/Jts/ibgateway/10.43.1a/tws.vmoptions
    cp "$ORIGIN_VM" /home/ibgateway/Jts/ibgateway/ibgateway.vmoptions
    cp "$ORIGIN_VM" /home/ibgateway/Jts/ibgateway/tws.vmoptions
    echo "✅ vmoptions 對齊完成"
fi

# 確保 jts.ini 存在
mkdir -p /home/ibgateway/Jts
[ ! -f /home/ibgateway/Jts/jts.ini ] && cp /home/ibgateway/Jts/jts.ini.tmpl /home/ibgateway/Jts/jts.ini 2>/dev/null

echo "--- 2. 帳密與連線設定注入 ---"
mkdir -p /root/ibc
[ -f /app/ibc/config.ini ] && cp /app/ibc/config.ini /root/ibc/config.ini
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

echo "--- 3. 啟動顯示環境 (VNC) ---"
rm -f /tmp/.X*lock
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg -rfbport 5900
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 4. 正式啟動 IB Gateway ---"
export _JAVA_OPTIONS="-Xmx768m -Xms256m -Djava.awt.headless=false"

/opt/ibc/scripts/ibcstart.sh 10.43.1a --gateway \
  --tws-path=/home/ibgateway/Jts/ibgateway \
  --tws-settings-path=/home/ibgateway/Jts \
  --ibc-path=/opt/ibc \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=live > /tmp/ibc_boot.log 2>&1 &

echo "--- 5. 啟動 Python 策略 (延遲 40 秒等待 Gateway 就緒) ---"
(sleep 40 && python3 /app/main.py > /tmp/python_app.log 2>&1) &

echo "--- 6. 永續監控與日誌輸出 ---"
(while true; do 
    echo "==== [$(date)] MONITORING ===="
    if ps aux | grep java | grep -v grep > /dev/null; then
        echo "✅ IB Gateway IS RUNNING"
    else
        echo "❌ IB Gateway NOT RUNNING. LOG SNIPPET:"
        [ -f /tmp/ibc_boot.log ] && tail -n 10 /tmp/ibc_boot.log
    fi
    sleep 30
done) &

tail -f /dev/null
EOF
RUN chmod +x /app/entrypoint.sh
EXPOSE 6080
ENTRYPOINT ["/app/entrypoint.sh"]