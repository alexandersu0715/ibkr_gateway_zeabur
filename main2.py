import asyncio
import os
from datetime import datetime
from ib_async import IB, Stock, StopOrder
from loguru import logger

# --- 設定區域 ---
HOST = '127.0.0.1'
PORT = int(os.getenv('TWS_PORT', 4001))
CLIENT_ID = int(os.getenv('IB_CLIENT_ID', 10))
SYMBOL = 'PGNY'  # 交易標的 (依據範例)

async def run_bot_loop(ib: IB):
    """
    策略邏輯：尋找 5 分鐘突破 (Gap Strategy)
    """
    logger.info(f"進入策略循環。交易標的: {SYMBOL}")
    
    # 1. 定義合約
    contract = Stock(SYMBOL, 'SMART', 'USD')
    await ib.qualifyContractsAsync(contract)
    logger.info(f"合約已確認: {contract.localSymbol}")

    # 狀態標記：避免重複交易 (簡單的單日邏輯)
    # 如果需要長期運行，建議加入日期檢查重置變數
    has_traded_today = False 
    current_date = datetime.now().date()

    while True:
        try:
            # 日期變更重置 (簡單實作)
            if datetime.now().date() != current_date:
                logger.info("日期變更，重置交易狀態。")
                current_date = datetime.now().date()
                has_traded_today = False

            if has_traded_today:
                logger.info("今日已完成交易或判斷完畢，等待明日...")
                await asyncio.sleep(60)
                continue

            # -------------------------------------------------------
            # 策略邏輯開始
            # -------------------------------------------------------
            
            # 2. 獲取昨日數據 (確認是否有顯著跳空)
            # 注意：這裡假設在開盤前後執行。若收盤後執行，邏輯可能需要調整。
            logger.info("正在獲取歷史數據以計算跳空...")
            bars = await ib.reqHistoricalDataAsync(
                contract, endDateTime='', durationStr='2 D',
                barSizeSetting='1 day', whatToShow='TRADES', useRTH=True
            )
            
            if len(bars) < 2:
                logger.warning("歷史數據不足 (需至少 2 日)，稍後重試...")
                await asyncio.sleep(60)
                continue

            prev_close = bars[-2].close
            logger.info(f"昨日收盤價: {prev_close}")

            # 3. 等待 5 分鐘 K 線 (Polling)
            # 這裡邏輯依據範例：持續詢問是否有最近 5 分鐘的 K 線
            logger.info("正在監測 5 分鐘 K 線...")
            
            first_bar = None
            # 嘗試獲取最近的 5 分 K
            bars_5m = await ib.reqHistoricalDataAsync(
                contract, endDateTime='', durationStr='300 S',
                barSizeSetting='5 mins', whatToShow='TRADES', useRTH=True
            )

            if not bars_5m:
                logger.info("尚未取得 5 分鐘 K 線，等待中...")
                await asyncio.sleep(10)
                continue
            
            first_bar = bars_5m[-1]
            high_price = first_bar.high
            low_price = first_bar.low
            
            # 判斷這根 K 線是否是 "開盤第一根"？
            # 範例程式碼未嚴格檢查時間，僅取當下獲取到的 K 線。
            # 實務上建議檢查 first_bar.date 是否為今日開盤時間 (例如 09:30 - 09:35 ET)
            # 這裡保留範例的簡化邏輯。
            logger.info(f"取得 5 分 K - 時間: {first_bar.date}, 高點: {high_price}, 低點: {low_price}")

            # 4. 計算跳空幅度
            gap_pct = (first_bar.open / prev_close - 1) * 100
            logger.info(f"今日跳空幅度: {gap_pct:.2f}%")

            if gap_pct > 2:  # 條件：跳空 > 2%
                quantity = 100  # 固定口數 (可調整)
                
                # 設定突破買入單 (Stop Order)
                buy_order = StopOrder('BUY', quantity, high_price)
                logger.warning(f"策略觸發！設定突破單：高於 {high_price} 買入 (數量: {quantity})")
                
                trade = ib.placeOrder(contract, buy_order)
                
                # 5. 風險管理：設定停損於 K 線低點
                # 注意：應等待買單成交後再掛停損，或使用觸發單 (Bracket Order)。
                # 範例代碼直接掛單，這裡稍微優化：等待成交或掛上 OCO (如果 IB 支援)。
                # 簡單起見，依範例直接掛停損單 (Stop Loss)
                stop_order = StopOrder('SELL', quantity, low_price)
                ib.placeOrder(contract, stop_order)
                logger.info(f"已掛設停損單於低點: {low_price}")

                # 監控直到訂單結束
                while trade.isActive():
                    await asyncio.sleep(1)
                
                if trade.orderStatus.status == 'Filled':
                    logger.success(f"已成交！成交價: {trade.orderStatus.avgFillPrice}")
                else:
                    logger.info(f"訂單狀態: {trade.orderStatus.status}")

            else:
                logger.info("跳空幅度不足 (>2%)，放棄今日交易。")

            # 標記今日已執行
            has_traded_today = True

        except Exception as e:
            logger.error(f"策略循環發生錯誤: {e}")
            await asyncio.sleep(5)

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

                # 設定行情數據類型 (延遲: 3, 即時: 1)
                ib.reqMarketDataType(3)
                logger.info("已設定市場數據類型為: 延遲行情 (Type 3)")

            # 啟動策略循環
            await run_bot_loop(ib)

        except (ConnectionError, OSError, asyncio.TimeoutError):
            logger.error("📡 連線中斷 (Connection Closed)，將在 60 秒後嘗試重連...")
        except Exception as e:
            logger.exception(f"⚠️ 發生未預期錯誤: {e}")
        finally:
            if ib.isConnected():
                ib.disconnect()
            await asyncio.sleep(60)

if __name__ == "__main__":
    # 設定日誌
    logger.add("main2.log", rotation="10 MB", level="INFO")
    
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("機器人手動停止。")
