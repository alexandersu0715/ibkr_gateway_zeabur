FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

ENV IBC_VERSION=3.23.0 \
    IBC_PATH=/opt/ibc \
    # 修改 TWS_PATH 指向，讓 IBC 的搜尋範圍與實際檔案對齊
    TWS_PATH=/home/ibgateway/Jts/ibgateway \
    DISPLAY=:99

# 1. 安裝工具
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

# 3. 建立啟動腳本
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 強制路徑物理對齊 ---"
# 強制給予整機 ibgateway 目錄權限
chmod -R 777 /home/ibgateway

# 解決 "Neither tws.vmoptions nor ibgateway.vmoptions could be found" 的終極手段：
# 把檔案「物理性」地複製到 IBC 搜尋的所有層級
TARGET_DIR="/home/ibgateway/Jts/ibgateway/10.43.1a"
PARENT_DIR="/home/ibgateway/Jts/ibgateway"

if [ -f "$TARGET_DIR/ibgateway.vmoptions" ]; then
    echo "Found vmoptions, performing physical sync..."
    cp "$TARGET_DIR/ibgateway.vmoptions" "$PARENT_DIR/ibgateway.vmoptions"
    cp "$TARGET_DIR/ibgateway.vmoptions" "$PARENT_DIR/tws.vmoptions"
    cp "$TARGET_DIR/ibgateway.vmoptions" "$TARGET_DIR/tws.vmoptions"
else
    echo "❌ 警告: 找不到原始 vmoptions 檔案！"
fi

# 確保 jts.ini 存在
mkdir -p /home/ibgateway/Jts
cp /home/ibgateway/Jts/jts.ini.tmpl /home/ibgateway/Jts/jts.ini 2>/dev/null || touch /home/ibgateway/Jts/jts.ini
chmod 777 /home/ibgateway/Jts/jts.ini

echo "--- 2. 帳密注入 ---"
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

# 再次確認路徑
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
    echo "==== [$(date)] MONITORING ===="
    if ps aux | grep java | grep -v grep > /dev/null; then
        echo "✅ IB Gateway IS RUNNING"
    else
        echo "❌ IB Gateway NOT RUNNING. DIAGNOSTIC:"
        [ -f /tmp/ibc_boot.log ] && tail -n 10 /tmp/ibc_boot.log
    fi
    sleep 30
done) &

tail -f /dev/null
EOF

RUN chmod +x /app/entrypoint.sh
EXPOSE 6080
ENTRYPOINT ["/app/entrypoint.sh"]