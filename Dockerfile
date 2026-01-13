# 使用 Python 3.12.7 基礎鏡像
FROM python:3.12.7-slim

# 設定環境變數
ENV IB_GATEWAY_VERSION=1019
ENV IBC_VERSION=3.20.0
ENV TWS_PATH=/root/Jts
ENV IBC_PATH=/root/ibc
ENV DISPLAY=:99

# 1. 安裝系統依賴 (Java, Xvfb, 網路工具)
RUN apt-get update && apt-get install -y \
    openjdk-17-jre \
    xvfb \
    libxtst6 \
    libxi6 \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# 2. 下載並安裝 IB Gateway (穩定版)
# 注意：此處 URL 需根據實測調整，或建議將安裝檔直接放入專案中 COPY 進去
RUN mkdir -p /opt/ibgateway && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/${IBC_VERSION}/IBCLinux-${IBC_VERSION}.zip -O /tmp/ibc.zip && \
    unzip /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh

# 3. 複製你的 Python 程式與 IBC 設定
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 4. 建立啟動腳本
# 腳本邏輯：啟動 Xvfb -> 啟動 IBC (Gateway) -> 運行 Python 程式
RUN echo "#!/bin/bash\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 3\n\
${IBC_PATH}/scripts/displaystart.sh &\n\
sleep 30\n\
python main.py" > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# 5. 執行
ENTRYPOINT ["/app/entrypoint.sh"]