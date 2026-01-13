FROM python:3.12.7-slim

# 設定環境變數
ENV TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99 \
    TWS_CONFIG_PATH=/root/Jts

# 1. 安裝必要套件 (參考 gnzsnz/ib 的依賴)
RUN apt-get update && apt-get install -y \
    openjdk-17-jre xvfb libxtst6 libxi6 libxrender1 libxinerama1 wget unzip procps \
    net-tools x11vnc novnc websockify fluxbox \
    && ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && rm -rf /var/lib/apt/lists/*

# 2. 下載並安裝最新穩定版 IBC & IB Gateway (Standalone)
RUN mkdir -p ${IBC_PATH} ${TWS_PATH} ${TWS_CONFIG_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/3.20.0/IBCLinux-3.20.0.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d ${TWS_PATH} && \
    rm /tmp/ibgateway-install.sh /tmp/ibc.zip

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 3. 建立啟動腳本 (配合 gnzsnz 風格的環境變數處理)
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
set +e

# 準備 IBC config
mkdir -p /root/ibc
cp /app/ibc/config.ini /root/ibc/config.ini

# 使用 Python 進行精準替換，避免特殊字元衝突
python3 -c "
import os
path = '/root/ibc/config.ini'
with open(path, 'r') as f: content = f.read()
content = content.replace('YOUR_USERNAME', os.getenv('IB_USER', ''))
content = content.replace('YOUR_PASSWORD', os.getenv('IB_PASS', ''))
# 強制設定 API 埠號與自動登錄
content = content.replace('AcceptIncomingAPIConnections=no', 'AcceptIncomingAPIConnections=yes')
with open(path, 'w') as f: f.write(content)
"

# 啟動虛擬桌面
rm -f /tmp/.X99-lock
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 3
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 啟動 IB Gateway ---"
export _JAVA_OPTIONS="-Xmx512M -Djava.awt.headless=false"
# 直接呼叫 IBC 啟動器
/opt/ibc/scripts/ibcstart.sh stable --gateway \
  --ibc-path=${IBC_PATH} --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} --pw=${IB_PASS} --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 啟動 Python 策略 ---"
(sleep 60 && python3 main.py > /tmp/python_app.log 2>&1) &

tail -f /dev/null
EOF

RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]