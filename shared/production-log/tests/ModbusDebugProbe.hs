{-# LANGUAGE CPP #-}
-- Compile against each actual Barcode module, without initializing a camera.
module Main where
import qualified Barcode as B
import qualified ProductionDebug as D
import Control.Concurrent
import Control.Monad
import Data.IORef

check :: String -> Bool -> IO ()
check name condition = unless condition (fail name)
readTrigger :: IO Bool
#ifdef BARCODE_APP
readTrigger = B.modbusTriggered
#else
readTrigger = (== "ok") <$> B.modbusTrigger
#endif
main :: IO ()
main = do
  B.modbusInit
  if not D.debugMode then do
    D.requestDebugTrigger >>= check "production must reject simulated requests" . not
    readTrigger >>= check "real trigger register 77"
    B.modbusOk
    B.modbusNg
    readTrigger >>= check "real trigger rearmed" . not
  else do
    readTrigger >>= check "idle is low" . not
    -- Simultaneous clicks must still latch exactly one request.
    responses <- replicateM 20 newEmptyMVar
    forM_ responses $ \response -> forkIO (D.requestDebugTrigger >>= putMVar response)
    results <- mapM takeMVar responses
    check "concurrent clicks admit one" (length (filter id results) == 1)
    readTrigger >>= check "queued pulse consumed"
    replicateM_ 4 (readTrigger >>= check "pulse is not held high" . not)
    D.requestDebugTrigger >>= check "running rejects another click" . not
    count <- newIORef (0 :: Int)
    replicateM_ 3 $ D.withDebugVerdict (modifyIORef' count (+1) >> B.modbusOk)
    readIORef count >>= check "scheduler verdict executes once" . (== 1)
    D.requestDebugTrigger >>= check "must sample low before rearming" . not
    readTrigger >>= check "rearm sample is low" . not
    D.withDebugVerdict (fail "completed state must not run again")
    D.requestDebugTrigger >>= check "next click accepted"
    readTrigger >>= check "second pulse consumed"
    B.modbusNg
    readTrigger >>= check "NG also rearms" . not
    D.debugCycleBusy >>= check "idle after NG" . not
  putStrLn "PASS: trigger, verdict and rearm"
