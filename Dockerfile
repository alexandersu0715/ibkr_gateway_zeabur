FROM python:3.12.7-slim

ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝套件
RUN apt-get update && apt-get install -y \
    openjdk-17-jre xvfb libxtst6 libxi6 libxrender1 libxinerama1 wget unzip procps \
    net-tools x11vnc novnc websockify python3-numpy fluxbox \
    && ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && rm -rf /var/lib/apt/lists/*

# 2. 下載並安裝 IBC
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d /tmp/ibc_temp && \
    if [ -d /tmp/ibc_temp/IBCLinux ]; then cp -r /tmp/ibc_temp/IBCLinux/* ${IBC_PATH}/; else cp -r /tmp/ibc_temp/* ${IBC_PATH}/; fi && \
    chmod -R 777 ${IBC_PATH} && rm -rf /tmp/ibc_temp /tmp/ibc.zip

# 3. 安裝 IB Gateway
RUN mkdir -p ${TWS_PATH} && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d ${TWS_PATH} && rm /tmp/ibgateway-install.sh

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 4. 建立 entrypoint.sh (改用 Python 注入帳密，避免 sed 衝突)
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
set -e
mkdir -p /root/ibc

echo "--- 注入帳密與準備環境 ---"
python3 -c "
import os
config_path = '/app/ibc/config.ini'
target_path = '/root/ibc/config.ini'
if os.path.exists(config_path):
    with open(config_path, 'r') as f: content = f.read()
    content = content.replace('YOUR_USERNAME', os.getenv('IB_USER', ''))
    content = content.replace('YOUR_PASSWORD', os.getenv('IB_PASS', ''))
    # 如果 config 裡本來就有設定，強制覆寫
    import re
    content = re.sub(r'IBUsername=.*', f'IBUsername={os.getenv(\"IB_USER\")}', content)
    content = re.sub(r'IBPassword=.*', f'IBPassword={os.getenv(\"IB_PASS\")}', content)
    with open(target_path, 'w') as f: f.write(content)
"

Xvfb :99 -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
sleep 2
x11vnc -display :99 -forever -shared -nopw -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 啟動 IBKR Gateway ---"
/opt/ibc/scripts/displaybannerandlaunch.sh \
  /opt/ibgateway /opt/ibc /root/ibc/config.ini \
  ${IB_GATEWAY_VERSION} gateway ${IB_USER} ${IB_PASS} > /tmp/ibc_boot.log 2>&1 &

echo "--- 啟動 Python 策略 ---"
python3 main.py > /tmp/python_app.log 2>&1 &

echo "--- 進入永續維護模式 ---"
tail -f /dev/null
EOF

RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]