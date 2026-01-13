FROM python:3.12.7-slim

# 設定環境變數
ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝基礎套件
# 包含 Java (執行 IBG), Xvfb (虛擬螢幕), Fluxbox (視窗管理), VNC (遠端查看)
RUN apt-get update && apt-get install -y \
    openjdk-17-jre \
    xvfb \
    libxtst6 \
    libxi6 \
    libxrender1 \
    libxinerama1 \
    wget \
    unzip \
    procps \
    net-tools \
    x11vnc \
    novnc \
    websockify \
    python3-numpy \
    fluxbox \
    && ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && rm -rf /var/lib/apt/lists/*

# 2. 下載並安裝 IBC (自動處理解壓後的目錄結構)
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d /tmp/ibc_temp && \
    if [ -d /tmp/ibc_temp/IBCLinux ]; then \
        cp -r /tmp/ibc_temp/IBCLinux/* ${IBC_PATH}/; \
    else \
        cp -r /tmp/ibc_temp/* ${IBC_PATH}/; \
    fi && \
    chmod -R 777 ${IBC_PATH} && \
    rm -rf /tmp/ibc_temp /tmp/ibc.zip

# 3. 安裝 IB Gateway (Standalone 版)
RUN mkdir -p ${TWS_PATH} && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d ${TWS_PATH} && \
    rm /tmp/ibgateway-install.sh

# 4. 設定 Python 工作環境
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 5. 建立 entrypoint.sh (使用 EOF 確保變數注入穩定性)
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
# 如果指令出錯則停止執行
set -e

# 準備 IBC 設定檔目錄
mkdir -p /root/ibc
if [ -f /app/ibc/config.ini ]; then
    cp /app/ibc/config.ini /root/ibc/config.ini
else
    echo "Warning: No config.ini found in /app/ibc/, creating blank file."
    touch /root/ibc/config.ini
fi

# 動態注入帳號密碼 (使用 @ 作為分隔符避免特殊字元錯誤)
sed -i "s@IBUsername=.*@IBUsername=${IB_USER}@" /root/ibc/config.ini
sed -i "s@IBPassword=.*@IBPassword=${IB_PASS}@" /root/ibc/config.ini

echo "--- 啟動虛擬顯示與 VNC ---"
Xvfb :99 -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
sleep 2
x11vnc -display :99 -forever -shared -nopw -bg
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 啟動 IBKR Gateway ---"
# 將日誌輸出到終端機方便監控
/opt/ibc/scripts/displaybannerandlaunch.sh \
  /opt/ibgateway \
  /opt/ibc \
  /root/ibc/config.ini \
  ${IB_GATEWAY_VERSION} \
  gateway \
  ${IB_USER} \
  ${IB_PASS} > /tmp/ibc_boot.log 2>&1 &

echo "--- 啟動 Python 策略 ---"
# 在背景執行 Python，避免它崩潰導致容器停止
python3 main.py > /tmp/python_app.log 2>&1 &

echo "--- 部署完成，容器進入永續維護模式 ---"
echo "您可以訪問 Networking 設定的網址查看 VNC 畫面"
# 保持容器前端運行，防止 Back-off
tail -f /dev/null
EOF

# 賦予執行權限
RUN chmod +x /app/entrypoint.sh

# 執行腳本
ENTRYPOINT ["/app/entrypoint.sh"]