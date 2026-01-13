# 1. 使用您指定的穩定基礎映像檔
FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

# 設定環境變數
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

# 4. 安裝 Python 套件
RUN pip3 install --no-cache-dir -r requirements.txt --break-system-packages --ignore-installed

# 5. 建立自動偵測啟動腳本
RUN cat <<'EOF' > /app/custom_entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 初始化目錄與注入帳密 ---"
mkdir -p /root/Jts /root/ibc
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

echo "--- 2. 啟動顯示環境 ---"
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
x11vnc -display :99 -forever -shared -nopw -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 3. 自動偵測 TWS 版本並啟動 ---"
# 掃描可能的安裝路徑來獲取版本號碼 (如 1043)
POSSIBLE_TWS_PATH="/opt/ibgateway"
TWS_VER=$(ls $POSSIBLE_TWS_PATH | grep -E '^[0-9]+' | head -n 1)

if [ -z "$TWS_VER" ]; then
    echo "❌ 找不到版本目錄，嘗試預設值 1043"
    TWS_VER="1043"
fi

echo "✅ 偵測到版本號: $TWS_VER，嘗試啟動..."

/opt/ibc/scripts/ibcstart.sh $TWS_VER --gateway \
  --tws-path=$POSSIBLE_TWS_PATH \
  --ibc-path=${IBC_PATH} \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 4. 啟動 Python 策略 ---"
(sleep 60 && python3 /app/main.py > /tmp/python_app.log 2>&1) &

echo "--- 5. 監控中 ---"
(while true; do 
    echo "==== [$(date)] MONITORING ===="
    ps aux | grep -E 'java|python3' | grep -v grep
    [ -f /tmp/ibc_boot.log ] && tail -n 10 /tmp/ibc_boot.log
    sleep 30
done) &

tail -f /dev/null
EOF

RUN chmod +x /app/custom_entrypoint.sh
EXPOSE 6080
ENTRYPOINT ["/app/custom_entrypoint.sh"]