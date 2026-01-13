FROM python:3.12.7-slim

ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝基礎套件
RUN apt-get update && apt-get install -y \
    openjdk-17-jre xvfb libxtst6 libxi6 libxrender1 libxinerama1 wget unzip procps \
    && rm -rf /var/lib/apt/lists/*

# 2. 下載並安裝 IBC (自動處理多餘資料夾)
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d /tmp/ibc_temp && \
    # 關鍵：將解壓後可能在子資料夾的檔案全部搬移到 /opt/ibc 根目錄
    if [ -d /tmp/ibc_temp/IBCLinux ]; then \
        cp -r /tmp/ibc_temp/IBCLinux/* ${IBC_PATH}/; \
    else \
        cp -r /tmp/ibc_temp/* ${IBC_PATH}/; \
    fi && \
    chmod -R 777 ${IBC_PATH} && \
    rm -rf /tmp/ibc_temp /tmp/ibc.zip

# 3. 安裝 IB Gateway (保持不變)
RUN mkdir -p ${TWS_PATH} && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d ${TWS_PATH} && \
    rm /tmp/ibgateway-install.sh

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 4. 建立 entrypoint.sh (針對 IBC 3.20.0 的腳本結構修正)
RUN echo '#!/bin/bash\n\
mkdir -p /root/ibc\n\
if [ -f /app/ibc/config.ini ]; then cp /app/ibc/config.ini /root/ibc/config.ini; fi\n\
sed -i "s/IBUsername=.*/IBUsername=${IB_USER}/" /root/ibc/config.ini\n\
sed -i "s/IBPassword=.*/IBPassword=${IB_PASS}/" /root/ibc/config.ini\n\
\n\
echo "--- 環境檢查 ---"\n\
echo "IBC 腳本清單:" && ls /opt/ibc/scripts\n\
\n\
echo "啟動虛擬螢幕..."\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 5\n\
\n\
echo "啟動 IBC 與 IB Gateway..."\n\
# 修正：使用 ibcstart.sh 並明確指定 Gateway 模式 (-g)\n\
# 指令格式：ibcstart.sh [版本] -g --tws-path=[path] --ibc-path=[path] --config-file=[path] --user=[user] --pw=[pass]\n\
/opt/ibc/scripts/ibcstart.sh ${IB_GATEWAY_VERSION} -g \
  --tws-path=${TWS_PATH} \
  --ibc-path=${IBC_PATH} \
  --config-file=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} &\n\
\n\
echo "等待 Gateway 啟動 (90s)..."\n\
sleep 90\n\
\n\
echo "啟動 Python 策略..."\n\
python main.py' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh