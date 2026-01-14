FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

# 根據你的 find 結果設定精確路徑
ENV IBC_VERSION=3.23.0 \
    IBC_PATH=/opt/ibc \
    TWS_PATH=/home/ibgateway/Jts/ibgateway \
    DISPLAY=:99

# 1. 安裝必要工具
RUN apt-get update && apt-get install -y \
    python3 python3-pip wget unzip procps \
    novnc websockify fluxbox x11vnc xvfb \
    && rm -rf /var/lib/apt/lists/*

# 2. 安裝 IBC 3.23.0
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

WORKDIR /app
COPY . .

# 3. 建立最終啟動腳本
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 物理路徑對齊 ---"
# 確保 Jts 目錄下有 jts.ini (從 tmpl 複製)
if [ ! -f /home/ibgateway/Jts/jts.ini ]; then
    cp /home/ibgateway/Jts/jts.ini.tmpl /home/ibgateway/Jts/jts.ini
fi

# 建立 IBC 設定檔目錄
mkdir -p /root/ibc
if [ -f /app/ibc/config.ini ]; then
    cp /app/ibc/config.ini /root/ibc/config.ini
else
    cp /opt/ibc/config.ini /root/ibc/config.ini
fi

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
    with open(path, 'w') as f: f.write(content)
"

echo "--- 3. 啟動顯示環境 ---"
rm -f /tmp/.X*lock
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg -rfbport 5900
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 4. 正式啟動 IBC ---"
export _JAVA_OPTIONS="-Xmx768m -Xms256m -Djava.awt.headless=false"

# 關鍵：TWS_PATH 指向包含 10.43.1a 的目錄
# 所有的 vmoptions 都在裡面了
/opt/ibc/scripts/ibcstart.sh 10.43.1a --gateway \
  --tws-path=/home/ibgateway/Jts/ibgateway \
  --tws-settings-path=/home/ibgateway/Jts \
  --ibc-path=/opt/ibc \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 5. 監控 ---"
(while true; do 
    echo "==== MONITORING ===="
    if ps aux | grep java | grep -v grep > /dev/null; then
        echo "✅ IB Gateway IS RUNNING"
    else
        echo "❌ IB Gateway NOT RUNNING. LOG:"
        [ -f /tmp/ibc_boot.log ] && tail -n 10 /tmp/ibc_boot.log
    fi
    sleep 30
done) &

tail -f /dev/null
EOF

RUN chmod +x /app/entrypoint.sh
EXPOSE 6080
ENTRYPOINT ["/app/entrypoint.sh"]