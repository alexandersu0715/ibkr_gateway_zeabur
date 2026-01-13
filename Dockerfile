FROM python:3.12.7-slim

ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝基礎套件 (加入 x11vnc 以供畫面查看)
RUN apt-get update && apt-get install -y \
    openjdk-17-jre xvfb libxtst6 libxi6 libxrender1 libxinerama1 wget unzip procps \
    x11vnc novnc websockify python3-numpy \
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

# 4. 建立 entrypoint.sh (修正語法，將 VNC 指令正確編入腳本)
RUN echo '#!/bin/bash\n\
mkdir -p /root/ibc\n\
if [ -f /app/ibc/config.ini ]; then cp /app/ibc/config.ini /root/ibc/config.ini; fi\n\
\n\
sed -i "s/IBUsername=.*/IBUsername=${IB_USER}/" /root/ibc/config.ini\n\
sed -i "s/IBPassword=.*/IBPassword=${IB_PASS}/" /root/ibc/config.ini\n\
\n\
echo "啟動虛擬螢幕與 VNC 服務..."\n\
Xvfb :99 -screen 0 1024x768x16 &\n\
sleep 5\n\
\n\
# 啟動 Web VNC (NoVNC) 以便從瀏覽器查看畫面\n\
websockify --web /usr/share/novnc/ 6080 localhost:5900 &\n\
x11vnc -display :99 -forever -shared -nopw -listen localhost -xkb &\n\
\n\
echo "準備啟動 IBC..."\n\
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
sleep 90\n\
\n\
echo "啟動 Python 策略..."\n\
exec python main.py' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]