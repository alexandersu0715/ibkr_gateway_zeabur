import os
import asyncio
import datetime
import math
from ib_async import *
from loguru import logger

# 1. Setup asyncio patch
util.patchAsyncio()

async def check_port(host, port):
    """檢查本地埠號是否已開啟，避免連線拒絕的錯誤噴發"""
    try:
        # 嘗試建立一個簡單的 TCP 連線
        _, writer = await asyncio.open_connection(host, port)
        writer.close()
        await writer.wait_closed()
        return True
    except:
        return False

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
        logger.error(f"Contract failed, trying fallback: {e}")