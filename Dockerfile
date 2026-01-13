# 1. 使用您指定的穩定基礎映像檔 (內建 10.43.1a)
FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

# 切換到 root 進行系統層級更新
USER root

# 設定固定版本環境變數
ENV IBC_VERSION=3.23.0 \
    IBC_PATH=/opt/ibc \
    TWS_PATH=/opt/ibgateway \
    DISPLAY=:99

# 2. 安裝 Python 策略環境與基礎工具 (增加 python3-venv 保持環境整潔)
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-numpy \
    novnc websockify fluxbox xterm wget unzip \
    && rm -rf /var/lib/apt/lists/*

# 3. 手動安裝/覆蓋為 IBC 3.23.0
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

# 4. 設定工作目錄並複製專案內容
WORKDIR /app
COPY . .

# 修正重點：使用 --ignore-installed 避開 numpy 卸載失敗的問題
RUN pip3 install --no-cache-dir -r requirements.txt --break-system-packages --ignore-installed

# 5. 建立啟動腳本 custom_entrypoint.sh
RUN cat <<'EOF' > /app/custom_entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 準備 IBC 設定檔 ---"
mkdir -p /root/ibc
if [ -f /app/ibc/config.ini ]; then
    cp /app/ibc/config.ini /root/ibc/config.ini
else
    cp /opt/ibc/config.ini /root/ibc/config.ini
fi

echo "--- 2. Python 安全注入帳密 (支援特殊字元) ---"
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
    print('✅ IBC 3.23.0 Config 準備就緒')
"

echo "--- 3. 啟動顯示與 VNC 轉發 ---"
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 4. 啟動 IB Gateway (指定版本 1043) ---"
export _JAVA_OPTIONS="-Xmx512M -Xms256M -Djava.awt.headless=false"

/opt/ibc/scripts/ibcstart.sh 1043 --gateway \
  --tws-path=${TWS_PATH} \
  --ibc-path=${IBC_PATH} \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 5. 啟動 Python 策略 ---"
(sleep 60 && python3 /app/main.py > /tmp/python_app.log 2>&1) &

echo "--- 6. 系統狀態輪詢 ---"
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