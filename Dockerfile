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
# ... 前面保持不變 ...

# 4. 建立 entrypoint.sh (改用最相容的啟動方式)
RUN echo '#!/bin/bash\n\
# 確保設定檔目錄存在\n\
mkdir -p /root/ibc\n\
if [ -f /app/ibc/config.ini ]; then cp /app/ibc/config.ini /root/ibc/config.ini; fi\n\
\n\
# 注入帳密到 config.ini (這是 IBC 最穩定的讀取方式)\n\
sed -i "s/IBUsername=.*/IBUsername=${IB_USER}/" /root/ibc/config.ini\n\
sed -i "s/IBPassword=.*/IBPassword=${IB_PASS}/" /root/ibc/config.ini\n\
\n\
echo "啟動虛擬螢幕..."\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 5\n\
\n\
echo "準備啟動 IBC..."\n\
# 這裡改用 displaybannerandlaunch.sh，它是針對 Xvfb 環境最穩定的啟動器\n\
# 參數順序: TWS_PATH, IBC_PATH, CONFIG_PATH, TWS_MAJOR_V, MODE, USER, PASS\n\
/opt/ibc/scripts/displaybannerandlaunch.sh \
  /opt/ibgateway \
  /opt/ibc \
  /root/ibc/config.ini \
  ${IB_GATEWAY_VERSION} \
  gateway \
  ${IB_USER} \
  ${IB_PASS} &\n\
\n\
echo "等待 Gateway 初始化 (90s)..."\n\
# 這裡很關鍵：我們需要確保後台進程不會讓容器結束\n\
# 如果 Python 沒跑起來，容器就會退出，所以我們用 tail 監控日誌或保持前台\n\
sleep 90\n\
\n\
echo "啟動 Python 策略..."\n\
# 使用 exec 讓 Python 成為主進程，防止容器退出\n\
exec python main.py' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]