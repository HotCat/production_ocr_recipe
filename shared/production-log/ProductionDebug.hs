-- One simulated PLC pulse enters the ordinary production pipeline. This module
-- owns no OCR/GUI logic: it only isolates real Modbus I/O and latches one click.
module ProductionDebug
  ( debugMode, requestDebugTrigger, consumeDebugTrigger, finishDebugTrigger
  , withDebugVerdict, debugCycleBusy
  ) where

import Control.Monad (when)
import Data.IORef
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

-- The launcher snapshots config.json at launch and always supplies 0 or 1.
-- Direct executions default to production mode; arbitrary strings never enable
-- simulation accidentally. Changing the flag requires restarting the client.
{-# NOINLINE debugMode #-}
debugMode :: Bool
debugMode = unsafePerformIO ((== Just "1") <$> lookupEnv "OCR_DEBUG_MODE")

data DebugCycle = Idle | Queued | Running | Finishing | Cooling deriving (Eq)

{-# NOINLINE cycleState #-}
cycleState :: IORef DebugCycle
cycleState = unsafePerformIO (newIORef Idle)

requestDebugTrigger :: IO Bool
requestDebugTrigger = if not debugMode then pure False else
  atomicModifyIORef' cycleState $ \state ->
    if state == Idle then (Queued, True) else (state, False)

-- Only the production trigger reader consumes this pulse. A complete false
-- sample after each result rearms the existing rising-edge/latch mechanisms.
consumeDebugTrigger :: IO Bool
consumeDebugTrigger = if not debugMode then pure False else
  atomicModifyIORef' cycleState $ \state -> case state of
    Queued -> (Running, True)
    Cooling -> (Idle, False)
    _ -> (state, False)

debugCycleBusy :: IO Bool
debugCycleBusy = if not debugMode then pure False else (/= Idle) <$> readIORef cycleState

finishDebugTrigger :: IO ()
finishDebugTrigger = when debugMode $
  atomicModifyIORef' cycleState $ \state ->
    (if state == Idle then Idle else Cooling, ())

-- Engraving schedulers expose a completed state for multiple rendered frames.
-- Claim the debug cycle once so a single click cannot append duplicate records
-- or increment the sequence repeatedly. Live PLC behavior is unchanged.
withDebugVerdict :: IO () -> IO ()
withDebugVerdict action
  | not debugMode = action
  | otherwise = do
      claimed <- atomicModifyIORef' cycleState $ \state ->
        if state == Running then (Finishing, True) else (state, False)
      when claimed action
