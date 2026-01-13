# 1. 使用您指定的穩定基礎映像檔
FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

# 設定環境變數 (移除 TWS_PATH，讓 IBC 自己找內建路徑)
ENV IBC_VERSION=3.23.0 \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 2. 安裝 Python 與工具
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-numpy \
    novnc websockify fluxbox xterm wget unzip \
    && rm -rf /var/lib/apt/lists/*

# 3. 更新為固定版本 IBC 3.23.0
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

WORKDIR /app
COPY . .

# 4. 安裝 Python 策略需要的套件 (忽略系統衝突)
RUN pip3 install --no-cache-dir -r requirements.txt --break-system-packages --ignore-installed

# 5. 建立啟動腳本
RUN cat <<'EOF' > /app/custom_entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 準備 IBC 設定檔 ---"
# 確保 Jts 資料夾存在 (解決報錯關鍵)
mkdir -p /root/Jts /root/ibc
if [ -f /app/ibc/config.ini ]; then
    cp /app/ibc/config.ini /root/ibc/config.ini
else
    cp /opt/ibc/config.ini /root/ibc/config.ini
fi

echo "--- 2. Python 注入帳密 ---"
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

echo "--- 3. 啟動顯示與 VNC ---"
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
# 同時啟動 VNC 桌面與 NoVNC 轉發
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 4. 啟動 IB Gateway (採用基礎映像檔預設路徑) ---"
export _JAVA_OPTIONS="-Xmx512M -Xms256M -Djava.awt.headless=false"

# 這裡不強行指定 --tws-path，讓 IBC 自己抓 /opt/ibgateway 內的預設路徑
/opt/ibc/scripts/ibcstart.sh 1043 --gateway \
  --ibc-path=${IBC_PATH} \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 5. 啟動 Python 策略 ---"
(sleep 60 && python3 /app/main.py > /tmp/python_app.log 2>&1) &

echo "--- 6. 系統監控 ---"
(while true; do 
    echo "==== [$(date)] MONITORING ===="
    ps aux | grep -E 'java|python3' | grep -v grep
    [ -f /tmp/ibc_boot.log ] && tail -n 5 /tmp/ibc_boot.log
    sleep 30
done) &

tail -f /dev/null
EOF

RUN chmod +x /app/custom_entrypoint.sh

# 暴露 NoVNC 埠號
EXPOSE 6080

ENTRYPOINT ["/app/custom_entrypoint.sh"]