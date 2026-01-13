FROM python:3.12.7-slim

ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝系統依賴
RUN apt-get update && apt-get install -y \
    openjdk-17-jre xvfb libxtst6 libxi6 libxrender1 libxinerama1 wget unzip procps \
    && rm -rf /var/lib/apt/lists/*

# 2. 安裝 IBC (改用 -j 扁平化所有檔案到同一層，避免目錄嵌套)
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o -j /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh

# 3. 安裝 IB Gateway
RUN mkdir -p ${TWS_PATH} && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d ${TWS_PATH} && \
    rm /tmp/ibgateway-install.sh

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 4. 強化版啟動腳本：自動定位 displaystart.sh
RUN echo '#!/bin/bash\n\
mkdir -p /root/ibc\n\
if [ -f /app/ibc/config.ini ]; then cp /app/ibc/config.ini /root/ibc/config.ini; fi\n\
sed -i "s/IBUsername=.*/IBUsername=${IB_USER}/" /root/ibc/config.ini\n\
sed -i "s/IBPassword=.*/IBPassword=${IB_PASS}/" /root/ibc/config.ini\n\
\n\
echo "啟動虛擬螢幕..."\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 5\n\
\n\
echo "搜尋並啟動 IBC..."\n\
# 自動尋找 displaystart.sh 的位置並執行\n\
LAUNCHER=$(find /opt/ibc -name "displaystart.sh" | head -n 1)\n\
if [ -z "$LAUNCHER" ]; then\n\
    echo "錯誤：找不到 displaystart.sh，嘗試直接呼叫 gatewaystart.sh"\n\
    LAUNCHER=$(find /opt/ibc -name "gatewaystart.sh" | head -n 1)\n\
fi\n\
\n\
echo "執行腳本: $LAUNCHER"\n\
$LAUNCHER /opt/ibgateway /opt/ibc /root/ibc/config.ini &\n\
\n\
echo "等待 Gateway 初始化 (90s)..."\n\
sleep 90\n\
\n\
echo "啟動 Python 策略程式..."\n\
python main.py' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]