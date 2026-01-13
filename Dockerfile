
FROM python:3.12.7-slim

# 設定環境變數
ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝系統套件
RUN apt-get update && apt-get install -y \
    openjdk-17-jre xvfb libxtst6 libxi6 libxrender1 libxinerama1 wget unzip procps \
    net-tools x11vnc novnc websockify python3-numpy fluxbox xterm \
    && ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && rm -rf /var/lib/apt/lists/*

# 2. 安裝 IBC
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

# 3. 安裝 IB Gateway
RUN mkdir -p ${TWS_PATH} && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d ${TWS_PATH} && \
    rm /tmp/ibgateway-install.sh

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 4. 建立 entrypoint.sh (包含強制 tail 與自動日誌輸出)
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
# 關閉 set -e，確保腳本出錯也會執行到最後的 tail
set +e

# 初始化目錄
mkdir -p /root/ibc /root/Jts
[ -f /app/ibc/config.ini ] && cp /app/ibc/config.ini /root/ibc/config.ini

echo "--- 1. Python 安全注入帳密 ---"
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
    with open(path, 'w') as f: f.write(content)
    print('✅ 設定檔注入成功')
"

echo "--- 2. 啟動顯示環境 ---"
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -ac -screen 0 1024x768x16 +extension RANDR +extension RENDER &
sleep 5
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg -rfbport 5900
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 3. 啟動 IB Gateway ---"
export _JAVA_OPTIONS="-Xmx512M -Djava.awt.headless=false"
# 確保日誌檔案存在
touch /tmp/ibc_boot.log

/opt/ibc/scripts/ibcstart.sh ${IB_GATEWAY_VERSION} --gateway \
  --tws-path=${TWS_PATH} \
  --ibc-path=${IBC_PATH} \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 4. 啟動 Python 策略 ---"
(sleep 60 && python3 main.py > /tmp/python_app.log 2>&1) &

echo "--- 5. 啟動自動日誌監控 (每 10 秒輸出到控制台) ---"
(while true; do 
    echo "==== IBC BOOT LOG UPDATE ===="
    tail -n 10 /tmp/ibc_boot.log
    sleep 10
done) &

echo "--- 6. 容器進入永續維護模式 ---"
# 最後這行保證容器絕對不會退出
tail -f /dev/null
EOF

RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]