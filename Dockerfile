FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

# 根據您的 ls 結果設定環境變數
ENV IBC_VERSION=3.23.0 \
    IBC_PATH=/opt/ibc \
    # 關鍵：TWS_PATH 必須是包含版本號資料夾的父目錄
    TWS_PATH=/root/Jts/ibgateway \
    DISPLAY=:99

# 1. 安裝工具
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-numpy \
    novnc websockify fluxbox xterm wget unzip \
    && rm -rf /var/lib/apt/lists/*

# 2. 強制更新 IBC 3.23.0
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

WORKDIR /app
COPY . .

# 3. 安裝 Python 套件
RUN pip3 install --no-cache-dir -r requirements.txt --break-system-packages --ignore-installed

# 4. 建立啟動腳本
RUN cat <<'EOF' > /app/custom_entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 初始化目錄與注入 ---"
mkdir -p /root/ibc
# 準備 IBC 設定檔
[ -f /app/ibc/config.ini ] && cp /app/ibc/config.ini /root/ibc/config.ini

# 根據您的 ls，確保 jts.ini 存在於正確位置
[ ! -f /root/Jts/jts.ini ] && cp /root/Jts/jts.ini.tmpl /root/Jts/jts.ini 2>/dev/null || touch /root/Jts/jts.ini

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

echo "--- 2. 啟動顯示環境 ---"
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 3. 啟動 IB Gateway (精確指向 10.43.1a) ---"
export _JAVA_OPTIONS="-Xmx512M -Xms256M -Djava.awt.headless=false"

# 這裡使用完整版本號 10.43.1a
/opt/ibc/scripts/ibcstart.sh 10.43.1a --gateway \
  --tws-path=/root/Jts/ibgateway \
  --ibc-path=/opt/ibc \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 4. 監控 ---"
(while true; do 
    echo "==== [$(date)] MONITORING ===="
    ps aux | grep java | grep -v grep || echo "⚠️ Java Gateway 尚未啟動"
    [ -f /tmp/ibc_boot.log ] && tail -n 5 /tmp/ibc_boot.log
    sleep 20
done) &

tail -f /dev/null
EOF

RUN chmod +x /app/custom_entrypoint.sh
ENTRYPOINT ["/app/custom_entrypoint.sh"]