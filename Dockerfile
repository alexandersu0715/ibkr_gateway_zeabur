FROM python:3.12.7-slim

# 設定環境變數
ENV IB_GATEWAY_VERSION=stable \
    IBC_VERSION=3.20.0 \
    TWS_PATH=/opt/ibgateway \
    IBC_PATH=/opt/ibc \
    DISPLAY=:99

# 1. 安裝系統套件
# 包含 Java (啟動 IBG), Xvfb (虛擬螢幕), Fluxbox (視窗管理), VNC/NoVNC (遠端桌面)
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

# 2. 下載並安裝 IBC (自動處理解壓目錄)
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

# 4. 設定 Python 環境
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt

# 5. 建立 entrypoint.sh (針對特殊字元密碼與穩定啟動進行最終優化)
RUN cat <<'EOF' > /app/entrypoint.sh
#!/bin/bash
# 即使指令出錯也繼續執行 tail，防止容器 Back-off 重啟
set +e

# 確保目錄存在
mkdir -p /root/ibc /root/Jts

echo "--- 1. 使用 Python 安全注入帳號密碼 ---"
python3 -c "
import os, re
config_path = '/app/ibc/config.ini'
target_path = '/root/ibc/config.ini'
user = os.getenv('IB_USER', '')
pw = os.getenv('IB_PASS', '')

if os.path.exists(config_path):
    with open(config_path, 'r') as f: content = f.read()
    # 處理範本佔位符替換
    content = content.replace('YOUR_USERNAME', user).replace('YOUR_PASSWORD', pw)
    # 強制覆寫設定行，避開 shell sed 對特殊符號 (@) 的錯誤解析
    content = re.sub(r'^IBUsername=.*', f'IBUsername={user}', content, flags=re.MULTILINE)
    content = re.sub(r'^IBPassword=.*', f'IBPassword={pw}', content, flags=re.MULTILINE)
    with open(target_path, 'w') as f: f.write(content)
    print('✅ 設定檔準備完成')
else:
    print('❌ 找不到 /app/ibc/config.ini')
"

echo "--- 2. 清理並啟動 X11 環境 ---"
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -ac -screen 0 1024x768x16 +extension RANDR +extension RENDER &
sleep 5
fluxbox -display :99 &
sleep 2

echo "--- 3. 啟動 VNC 與 NoVNC ---"
x11vnc -display :99 -forever -shared -nopw -bg -rfbport 5900
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 4. 啟動 IBKR Gateway (透過 IBC) ---"
# 設定 Java 記憶體限制與圖形參數，避免 Zeabur OOM 殺掉程序
export _JAVA_OPTIONS="-Xmx512M -Xms256M -Djava.awt.headless=false"

nohup /opt/ibc/scripts/ibcstart.sh ${IB_GATEWAY_VERSION} \
  --gateway \
  --tws-path=${TWS_PATH} \
  --ibc-path=${IBC_PATH} \
  --ibc-ini=/root/ibc/config.ini \
  --user=${IB_USER} \
  --pw=${IB_PASS} \
  --mode=paper > /tmp/ibc_boot.log 2>&1 &

echo "--- 5. 啟動 Python 策略 (延遲 60 秒啟動) ---"
(sleep 60 && python3 main.py > /tmp/python_app.log 2>&1) &

echo "--- 6. 容器進入永續維護模式 ---"
echo "請訪問 VNC 網址查看 2FA 視窗"
# 保持主進程，絕對不讓容器退出
tail -f /dev/null
EOF

RUN chmod +x /app/entrypoint.sh

# 6. 執行
ENTRYPOINT ["/app/entrypoint.sh"]