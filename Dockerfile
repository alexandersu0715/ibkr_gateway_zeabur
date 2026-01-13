# 1. 使用官方 Python 3.12.7 基礎鏡像
FROM python:3.12.7-slim

# 設定環境變數
ENV IB_GATEWAY_VERSION=stable
ENV IBC_VERSION=3.20.0
ENV TWS_PATH=/root/Jts
ENV IBC_PATH=/root/ibc
ENV DISPLAY=:99

# 2. 安裝系統依賴
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

# 3. 安裝 IBC (加入 -o 參數強制覆蓋，避免互動提問)
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    # -o 代表 overwrite (覆蓋), -j 代表 junk paths (不保留原始資料夾結構)
    unzip -o -j /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh

# 4. 安裝 IB Gateway
RUN mkdir -p /opt/ibgateway && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d /opt/ibgateway && \
    rm /tmp/ibgateway-install.sh

# 5. 設定 Python 工作目錄
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 6. 修正後的啟動腳本
# 注意：IBC 在 Linux 上啟動 Gateway 的腳本是 gatewaystart.sh
RUN echo '#!/bin/bash\n\
mkdir -p /root/ibc\n\
# 複製專案內的設定檔到 IBC 預設路徑\n\
if [ -f /app/ibc/config.ini ]; then \n\
    cp /app/ibc/config.ini /root/ibc/config.ini\n\
else\n\
    echo "錯誤: 找不到 /app/ibc/config.ini"\n\
fi\n\
\n\
# 動態注入 Zeabur 環境變數\n\
sed -i "s/IBUsername=.*/IBUsername=${IB_USER}/" /root/ibc/config.ini\n\
sed -i "s/IBPassword=.*/IBPassword=${IB_PASS}/" /root/ibc/config.ini\n\
\n\
echo "啟動虛擬螢幕..."\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 5\n\
\n\
echo "啟動 IBC 與 IB Gateway..."\n\
# 執行 gatewaystart.sh 並傳入必要的路徑參數\n\
# 格式: gatewaystart.sh [tws_path] [ibc_path] [config_file]\n\
/root/ibc/gatewaystart.sh /opt/ibgateway /root/ibc /root/ibc/config.ini &\n\
\n\
echo "等待 Gateway 初始化 (90s)..."\n\
sleep 90\n\
\n\
echo "啟動 Python 策略程式..."\n\
python main.py' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]