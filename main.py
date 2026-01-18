import asyncio
import os
from datetime import datetime
from ib_async import IB, Stock, LimitOrder, StopOrder

# --- 設定區域 ---
HOST = '127.0.0.1'
PORT = int(os.getenv('TWS_PORT', 4001))
CLIENT_ID = int(os.getenv('IB_CLIENT_ID', 10))
SYMBOL = 'PGNY'  # 影片中提到的跳空範例股

async def run_bot_loop(ib: IB):
    """
    策略邏輯：尋早5min突破的買入策略 (PGNY)
    """
    logger.info(f"進入策略循環。交易標的: {SYMBOL}")
    
    # 1. 定義合約 (PGNY)
    contract = Stock(SYMBOL, 'SMART', 'USD')
    await ib.qualifyContractsAsync(contract)
    logger.info(f"合約已確認: {contract.localSymbol}")

    # 狀態標記：今日是否已執行判斷
    current_date = datetime.now().date()
    # 簡單標記：若已執行過策略邏輯 (無論是否有交易)，今日不再執行，除非重啟
    has_executed_today = False 

    while True:
        try:
            # 日期變更檢查
            if datetime.now().date() != current_date:
                logger.info("日期變更，重置執行狀態。")
                current_date = datetime.now().date()
                has_executed_today = False

            if has_executed_today:
                # 今日已結束，等待
                await asyncio.sleep(60)
                continue

            # -------------------------------------------------------
            # 策略邏輯開始
            # -------------------------------------------------------
            logger.info("準備執行 5 分鐘突破策略邏輯...")

            # 2. 獲取昨日數據 (確認是否有顯著跳空)
            logger.info("正在獲取歷史數據以計算跳空...")
            bars = await ib.reqHistoricalDataAsync(
                contract, endDateTime='', durationStr='2 D',
                barSizeSetting='1 day', whatToShow='TRADES', useRTH=True
            )
            
            if len(bars) < 2:
                logger.warning("歷史數據不足 (需至少 2 日)，稍後重試...")
                # 暫時不標記已執行，讓它稍後重試直到數據可用 (例如剛開盤)
                await asyncio.sleep(60)
                continue

            prev_close = bars[-2].close
            logger.info(f"昨日收盤價: {prev_close}")

            # 3. 等待開盤並獲取第一根 5 分鐘 K 線
            logger.info("等待開盤後的第一根 5 分鐘 K 線完成...")
            first_bar = None
            
            # 這裡我們做一個 polling loop 等待 5 分 K 出現
            # 注意：若當前時間已經遠超過開盤，這裡會直接拿最近的 5 分 K。
            # 若要嚴格限制 "開盤第一根"，需要檢查時間戳。
            # 依據用戶範例邏輯，這裡簡化為 "等待直到有 5 分 K"
            while True:
                bars_5m = await ib.reqHistoricalDataAsync(
                    contract, endDateTime='', durationStr='300 S',
                    barSizeSetting='5 mins', whatToShow='TRADES', useRTH=True
                )
                if bars_5m:
                    first_bar = bars_5m[-1]
                    high_price = first_bar.high
                    low_price = first_bar.low
                    logger.info(f"5分K完成 - 高點: {high_price}, 低點: {low_price}")
                    break
                
                # 若尚未取得，等待 10 秒
                if not ib.isConnected(): raise ConnectionError("IB Disconnected")
                await asyncio.sleep(10)

            # 4. 執行策略邏輯：突破第一根 K 線高點買進
            gap_pct = (first_bar.open / prev_close - 1) * 100
            logger.info(f"今日跳空幅度: {gap_pct:.2f}%")

            if gap_pct > 2:  # 假設至少跳空 2% 
                quantity = 100  # 請根據帳戶規模調整
                
                # 設定突破買入單 (Stop Order)
                buy_order = StopOrder('BUY', quantity, high_price)
                logger.warning(f"設定突破單：高於 {high_price} 買入")
                
                trade = ib.placeOrder(contract, buy_order)
                
                # 5. 風險管理：設定停損於第一根 K 線低點
                # 依範例直接掛出 (注意：若買單未成交，停損單也會掛出成為空單，這是雙向掛單邏輯嗎？)
                # 原範例代碼：Place stop order (Buy) AND Place stop order (Sell - Quantity 100).
                # 如果是 "買入後停損"，通常應等待成交或使用 Bracket Order。
                # 但依據用戶提供的代碼邏輯："stop_order = StopOrder('SELL', quantity, low_price); ib.placeOrder..."
                # 這是一個明顯的 "突破單 + 停損單" 同時掛出的邏輯。若這不是 Bracket，則可能會有裸露風險。
                # 但我必須 "遵守參考代碼"。參考代碼就是這樣寫的。
                # (註：Stop Sell Order 低於市價會等待觸發。如果未持有倉位，這會變成做空單。)
                # 假設用戶清楚這點，或假設這是 Bracket 的簡化寫法? 
                # 為了安全且符合 "策略參考"，我將忠實還原，但添加註解。
                
                stop_order = StopOrder('SELL', quantity, low_price)
                ib.placeOrder(contract, stop_order)
                logger.info(f"已掛設停損單於低點: {low_price}")

                # 監控交易直到結束 
                # (注意：這裡的 logic 會 block 住直到 trade active 結束，這可能很久)
                # 為了避免 bot 卡死在 "監控"，我們把監控放寬或直接結束 "判斷階段"。
                # 用戶代碼有： while trade.isActive(): await asyncio.sleep(1)
                # 這意味著它會一直等到成交或取消。
                logger.info("正在監控訂單狀態...")
                while trade.isActive():
                    if not ib.isConnected(): raise ConnectionError("IB Disconnected")
                    await asyncio.sleep(1)
                
                if trade.orderStatus.status == 'Filled':
                    logger.success(f"已成交！成交價: {trade.orderStatus.avgFillPrice}")
            else:
                logger.info("跳空幅度不足 (>2%)，放棄今日交易。")

            # 標記今日已執行
            has_executed_today = True

        except Exception as e:
            logger.error(f"策略執行錯誤: {e}")
            await asyncio.sleep(5)
            # 發生錯誤不跳出 while True，重試或等待


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