# 1. 使用官方 Python 3.12.7 基礎鏡像
FROM python:3.12.7-slim

# 設定環境變數
ENV IB_GATEWAY_VERSION=stable
ENV IBC_VERSION=3.20.0
ENV TWS_PATH=/root/Jts
ENV IBC_PATH=/root/ibc
ENV DISPLAY=:99

# 2. 安裝系統依賴 (Java, Xvfb, 網路工具, 還有文字處理用的 sed)
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
    && rm -rf /var/lib/apt/lists/*

# 3. 安裝 IBC (修正解壓縮邏輯，確保 scripts 資料夾直接在 /root/ibc 下)
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip -j /tmp/ibc.zip -d ${IBC_PATH} && \
    # 注意：-j 會扁平化檔案，所以我們要手動建立 scripts 資料夾或修正路徑
    chmod +x ${IBC_PATH}/*.sh
	
# 4. 安裝 IB Gateway (自動下載最新穩定版安裝腳本)
RUN mkdir -p /opt/ibgateway && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d /opt/ibgateway && \
    rm /tmp/ibgateway-install.sh

# 5. 設定 Python 工作目錄
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 6. 修正啟動腳本 entrypoint.sh 中的路徑
RUN echo '#!/bin/bash\n\
mkdir -p /root/ibc\n\
# 這裡假設你的專案裡有 ibc/config.ini\n\
if [ -f /app/ibc/config.ini ]; then cp /app/ibc/config.ini /root/ibc/config.ini; fi\n\
\n\
sed -i "s/IBUsername=.*/IBUsername=${IB_USER}/" /root/ibc/config.ini\n\
sed -i "s/IBPassword=.*/IBPassword=${IB_PASS}/" /root/ibc/config.ini\n\
\n\
echo "啟動虛擬螢幕..."\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 5\n\
\n\
echo "啟動 IBC 與 IB Gateway..."\n\
# 關鍵修正：直接執行腳本，路徑需與安裝時一致\n\
/root/ibc/displaystart.sh &\n\
\n\
echo "等待 Gateway 初始化 (90s)..."\n\
sleep 90\n\
\n\
echo "啟動 Python 策略程式..."\n\
python main.py' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# 7. 執行
ENTRYPOINT ["/app/entrypoint.sh"]