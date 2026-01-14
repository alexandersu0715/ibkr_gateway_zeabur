# 1. 使用基礎映像檔
FROM ghcr.io/gnzsnz/ib-gateway:10.43.1a

USER root

# 設定環境變數，將 DISPLAY 指向 :99
ENV DISPLAY=:99 \
    IBC_PATH=/opt/ibc

# 2. 安裝必要工具（確保有 xterm 可以讓你 VNC 進去後操作）
RUN apt-get update && apt-get install -y \
    python3 python3-pip wget unzip procps net-tools \
    novnc websockify fluxbox xterm x11vnc xvfb \
    && rm -rf /var/lib/apt/lists/*

# 3. 安裝 IBC 3.23.0 (僅解壓縮，不啟動)
RUN mkdir -p ${IBC_PATH} && \
    wget -q https://github.com/IbcAlpha/IBC/releases/download/3.23.0/IBCLinux-3.23.0.zip -O /tmp/ibc.zip && \
    unzip -o /tmp/ibc.zip -d ${IBC_PATH} && \
    chmod +x ${IBC_PATH}/*.sh ${IBC_PATH}/scripts/*.sh && \
    rm /tmp/ibc.zip

WORKDIR /app
COPY . .

# 4. 建立「純診斷」啟動腳本
RUN cat <<'EOF' > /app/debug_entrypoint.sh
#!/bin/bash
set +e

echo "--- 1. 清理與啟動顯示環境 ---"
rm -f /tmp/.X*lock
Xvfb :99 -ac -screen 0 1024x768x16 &
sleep 2
fluxbox -display :99 &
# 啟動 VNC 伺服器
x11vnc -display :99 -forever -shared -nopw -bg -rfbport 5900
# 啟動 NoVNC 網頁轉發
websockify --web /usr/share/novnc 6080 localhost:5900 &

echo "--- 2. 在 VNC 中啟動一個終端機 ---"
# 這樣你一連上 VNC 就會看到一個視窗可以打字
DISPLAY=:99 xterm -geometry 100x30+10+10 &

echo "--- 3. 進入無限等待 (防止容器崩潰) ---"
echo "系統已穩定。請連上 VNC 網頁開始偵錯。"
tail -f /dev/null
EOF

RUN chmod +x /app/debug_entrypoint.sh

# 暴露 NoVNC 埠號
EXPOSE 6080

# 覆蓋所有內建的 ENTRYPOINT，強制執行診斷腳本
ENTRYPOINT ["/app/debug_entrypoint.sh"]