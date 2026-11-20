module Main where
import ProductionLog
import qualified ProductionDebug as D
import System.Environment (getArgs)
import Control.Monad (forM_, unless)

-- Exercises the real writer without loading any camera or PLC modules.
main :: IO ()
main = do
  args <- getArgs
  let app = head args
  unless (drop 1 args == ["insert-only"]) (initializeProductionLog app)
  if drop 1 args == ["debug-cycles"] then
    forM_ [True, False] $ \passed -> do
      accepted <- D.requestDebugTrigger
      unless accepted (fail "debug request rejected")
      triggered <- D.consumeDebugTrigger
      unless triggered (fail "missing debug pulse")
      -- Scheduler exposes a final result for several frames, but writes once.
      forM_ [1..3 :: Int] $ \_ -> D.withDebugVerdict $ do
        recordProduction $ (productionEvent app passed) { eventBarcode = "SAME001" }
        D.finishDebugTrigger
      D.consumeDebugTrigger
      pure ()
  else if drop 1 args == ["init"] then pure () else
    forM_ [True,False] $ \passed -> recordProduction $ (productionEvent app passed)
      { eventBarcode = "ABC'\\包装\n001\0END"
      , eventPackagingBarcode = "ABC'\\包装\n001\0END"
      , eventSerial = "0012345678901234", eventDetected = "客服电话：96008 ABC\n第二行"
      , eventPreset = "客服电话:96008 ABC第二行", eventBank = "未来银行"
      , eventBankIndex = Just 2, eventBankSerialLength = Just 16
      , eventGuard = Just True, eventReverse = Just False
      , eventPackagingGuard = Just False, eventReason = "测试" }
