FROM python:3.12.7-slim

ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝基礎套件 (加入 x11vnc, novnc 與建立首頁連結)
RUN apt-get update && apt-get install -y \
    openjdk-17-jre xvfb libxtst6 libxi6 libxrender1 libxinerama1 wget unzip procps \
    x11vnc novnc websockify python3-numpy \
    && ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html \
    && rm -rf /var/lib/apt/lists/*

# 2. 下載並安裝 IBC
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

WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 4. 建立 entrypoint.sh
RUN echo '#!/bin/bash\n\
mkdir -p /root/ibc\n\
if [ -f /app/ibc/config.ini ]; then cp /app/ibc/config.ini /root/ibc/config.ini; fi\n\
\n\
# 注入帳密\n\
sed -i "s/IBUsername=.*/IBUsername=${IB_USER}/" /root/ibc/config.ini\n\
sed -i "s/IBPassword=.*/IBPassword=${IB_PASS}/" /root/ibc/config.ini\n\
\n\
echo "1. 啟動虛擬螢幕與 VNC..."\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 3\n\
x11vnc -display :99 -forever -shared -nopw -xkb &\n\
websockify --web /usr/share/novnc 6080 localhost:5900 &\n\
\n\
echo "2. 啟動 IBC..."\n\
/opt/ibc/scripts/displaybannerandlaunch.sh /opt/ibgateway /opt/ibc /root/ibc/config.ini ${IB_GATEWAY_VERSION} gateway ${IB_USER} ${IB_PASS} &\n\
\n\
echo "3. 啟動 Python 策略 (背景執行)..."\n\
python main.py &\n\
\n\
echo "4. 容器進入永續模式，請訪問 Networking 生成的網址查看畫面..."\n\
tail -f /dev/null' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]