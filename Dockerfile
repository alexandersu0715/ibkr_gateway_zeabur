FROM python:3.12.7-slim

# 設定環境變數
ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝基礎套件
# 加入 fluxbox (視窗管理員) 解決黑屏問題
# 加入 net-tools 以供 netstat 檢查端口
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

# 2. 下載並安裝 IBC (自動處理層級結構)
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

# 3. 安裝 IB Gateway
RUN mkdir -p ${TWS_PATH} && \
    wget -q https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh -O /tmp/ibgateway-install.sh && \
    chmod +x /tmp/ibgateway-install.sh && \
    /tmp/ibgateway-install.sh -q -d ${TWS_PATH} && \
    rm /tmp/ibgateway-install.sh

# 4. 設定 Python 環境
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt