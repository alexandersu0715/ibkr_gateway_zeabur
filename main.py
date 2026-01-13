import os
import asyncio
import datetime
import math
from ib_async import *
from loguru import logger

# 1. Setup asyncio patch
util.patchAsyncio()

def get_utc_now():
    """確保取得的是帶有時區資訊的 UTC 時間"""
    return datetime.datetime.now(datetime.timezone.utc)

async def get_usd_cash(ib):
    """獲取帳戶餘額"""
    account_summary = await ib.accountSummaryAsync()
    for tag in account_summary:
        if tag.tag == 'TotalCashValue' and tag.currency == 'USD':
            return float(tag.value)
    return 0.0

async def place_and_manage_order(ib, contract, buy_amount, cash_threshold, cancel_time_utc):
    try:
        usd_cash = await get_usd_cash(ib)
        logger.info(f"當前可用 USD 現金: {usd_cash}")
        
        if usd_cash <= cash_threshold:
            logger.warning(f"現金 (${usd_cash}) 低於門檻 (${cash_threshold})，取消本次交易。")
            return

        # 切換至延遲行情（若無實時訂閱）
        ib.reqMarketDataType(3) 
        ticker = ib.reqMktData(contract, '', False, False)
        
        # 等待有效報價
        for _ in range(15):
            await asyncio.sleep(1)
            if ticker.bid and ticker.bid > 0 and not math.isnan(ticker.bid):
                break
        
        if ticker.bid is None or ticker.bid <= 0 or math.isnan(ticker.bid):
            logger.error(f"無法獲取有效 Bid 價格 (目前: {ticker.bid})，跳過此時段。")
            return

        # LSE 價格通常較精細，round 到 2 位或 4 位視合約而定，這裡維持 2 位
        limit_price = round(ticker.bid + 0.01, 2)
        quantity = int(buy_amount // limit_price)
        
        if quantity <= 0:
            logger.error(f"計算數量為 0 (價格: {limit_price})。")
            return

        logger.info(f"送出限價買單: {quantity} 股 @ {limit_price}")
        order = LimitOrder('BUY', quantity, limit_price)
        trade = ib.placeOrder(contract, order)

        # 監控直到成交或超時
        while get_utc_now() < cancel_time_utc:
            if not ib.isConnected():
                 raise ConnectionError("監控期間連線中斷")
            if trade.isDone():
                logger.success(f"訂單已成交！狀態: {trade.orderStatus.status}")
                return
            await asyncio.sleep(10)

        # 超時取消
        if not trade.isDone():
            logger.warning(f"到達時間上限 ({cancel_time_utc})，撤單中...")
            ib.cancelOrder(order)
            await asyncio.sleep(2)
            logger.info(f"訂單最終狀態: {trade.orderStatus.status}")

    except Exception as e:
        logger.exception(f"執行訂單時發生錯誤: {e}")

async def run_bot_loop(ib):
    # LSE SWRD 合約設定
    contract = Stock('SWRD', 'SMART', 'USD', primaryExchange='LSE')
    
    try:
        await ib.qualifyContractsAsync(contract)
        logger.info(f"合約確認成功: {contract}")
    except Exception as e:
        logger.error(f"合約確認失敗，嘗試後備方案: {e}")
        contract = Stock('SWRD', 'LSE', 'USD')
        await ib.qualifyContractsAsync(contract)

    current_date = get_utc_now().date()
    traded_1030 = False
    traded_1400 = False

    logger.info(f"機器人啟動。當前 UTC 日期: {current_date}")

    while True:
        if not ib.isConnected():
            raise ConnectionError("IB 連線遺失")

        now = get_utc_now()
        
        # 跨日重置旗標
        if now.date() != current_date:
            current_date = now.date()
            traded_1030 = False
            traded_1400 = False
            logger.info(f"新的一天開始: {current_date}，重置交易標記。")

        # --- 時段 1: 10:30 UTC ---
        if not traded_1030 and (10 <= now.hour < 14):
            if now.hour == 10 and now.minute >= 30 or now.hour > 10:
                cancel_time = now.replace(hour=13, minute=55, second=0)
                logger.info("觸發 10:30 UTC 交易時段")
                await place_and_manage_order(ib, contract, 5000, 5100, cancel_time)
                traded_1030 = True

        # --- 時段 2: 14:00 UTC ---
        if not traded_1400 and (14 <= now.hour < 16):
            cancel_time = now.replace(hour=15, minute=55, second=0)
            logger.info("觸發 14:00 UTC 交易時段")
            await place_and_manage_order(ib, contract, 5000, 5100, cancel_time)
            traded_1400 = True

        await asyncio.sleep(30)

async def main():
    # 讀取 Zeabur 環境變數
    host = os.getenv('IB_HOST', '127.0.0.1')
    port = int(os.getenv('IB_PORT', 4002))
    client_id = int(os.getenv('CLIENT_ID', 10))

    while True:
        ib = IB()
        try:
            logger.info(f"嘗試連線至 IBKR Gateway ({host}:{port})...")
            await ib.connectAsync(host, port, clientId=client_id)
            logger.success("連線成功，啟動邏輯循環。")
            await run_bot_loop(ib)
        except Exception as e:
            logger.error(f"主程式崩潰或連線失敗: {e}")
        finally:
            ib.disconnect()
        
        logger.info("60 秒後嘗試重新連線...")
        await asyncio.sleep(60)

if __name__ == "__main__":
    asyncio.run(main())