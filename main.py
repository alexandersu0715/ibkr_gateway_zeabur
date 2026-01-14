import asyncio
import os
from datetime import datetime
from ib_async import IB, Stock, LimitOrder
from loguru import logger

# --- 設定區域 ---
HOST = '127.0.0.1'
PORT = int(os.getenv('TWS_PORT', 4001))
CLIENT_ID = int(os.getenv('IB_CLIENT_ID', 10))
SYMBOL = 'SWRD'  # 您要交易的標的

async def run_bot_loop(ib: IB):
    """
    這裡放置您的交易策略核心邏輯。
    """
    logger.info(f"進入策略循環。交易標的: {SYMBOL}")
    
    # 定義合約 (LSE 交易所的 SWRD)
    contract = Stock(SYMBOL, 'SMART', 'USD', primaryExchange='LSEETF')
    
    while True:
        # 1. 檢查連線狀態 (心跳檢測)
        await ib.reqCurrentTimeAsync()
        
        # 2. 獲取當前帳戶餘額或持倉 (範例)
        # positions = ib.positions()
        # logger.info(f"當前持倉數量: {len(positions)}")

        # 3. 策略邏輯執行點
        now_utc = datetime.utcnow()
        logger.info(f"機器人運行中... 當前時間 (UTC): {now_utc.strftime('%Y-%m-%d %H:%M:%S')}")

        # --- 在此加入您的買賣判斷 ---
        # 範例：如果到了特定時間執行動作
        # if now_utc.hour == 10 and now_utc.minute == 30:
        #     order = LimitOrder('BUY', 1, 35.00)
        #     trade = ib.placeOrder(contract, order)
        #     logger.warning(f"送出訂單: {trade}")

        # 保持循環，每 60 秒檢查一次
        await asyncio.sleep(60)

async def main():
    """
    主程式：負責連線管理與異常重連。
    """
    ib = IB()
    
    while True:
        try:
            if not ib.isConnected():
                logger.info(f"正在連線至 IBKR Gateway ({HOST}:{PORT}) clientId={CLIENT_ID}...")
                
                # 連線至 Gateway
                await ib.connectAsync(HOST, PORT, clientId=CLIENT_ID, timeout=30)
                logger.success("✅ 連線成功！")

                # 重要：設定行情數據類型
                # 3 = 延遲行情 (若您沒買即時數據，這能防止報錯)
                # 1 = 即時行情
                ib.reqMarketDataType(3)
                logger.info("已設定市場數據類型為: 延遲行情 (Type 3)")

                # 確認合約有效性
                contract = Stock(SYMBOL, 'SMART', 'USD', primaryExchange='LSEETF')
                qualified_contracts = await ib.qualifyContractsAsync(contract)
                if qualified_contracts:
                    logger.info(f"🎯 合約確認成功: {qualified_contracts[0].localSymbol}")
                else:
                    logger.error("❌ 無法識別合約，請檢查代碼或交易所設定")

            # 啟動策略循環
            await run_bot_loop(ib)

        except (ConnectionError, OSError, asyncio.TimeoutError):
            logger.error("📡 連線中斷 (Connection Closed)，將在 60 秒後嘗試重連...")
        except Exception as e:
            logger.exception(f"⚠️ 發生未預期錯誤: {e}")
        finally:
            # 確保清理舊連線
            if ib.isConnected():
                ib.disconnect()
            
            # 等待重連緩衝
            await asyncio.sleep(60)

if __name__ == "__main__":
    # 設定日誌格式
    logger.add("/tmp/python_app.log", rotation="10 MB", level="INFO")
    
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("機器人手動停止。")