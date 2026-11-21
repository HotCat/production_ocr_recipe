{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
-- The actual application's Yampa network, including switches and control-map
-- lookups. Force every returned action closure exactly as Main does, but never
-- execute it: no GUI, camera, PLC, database or OCR side effects in this probe.
module Main where
import FRP.Yampa
import Object
import Language.Scheme.Types (OcrState(..))
import Parser
import ObjectBehavior
#ifdef BARCODE_APP
import Barcode (newBarcodeRuntime)
#endif
import qualified Data.Map.Strict as Map
import Data.IORef
import GHC.Clock
import GHC.Stats
import System.CPUTime
import System.Mem (performGC)
import System.Random (mkStdGen)
import System.Environment (getArgs)
import Text.Printf
import Control.Exception (evaluate)
import Control.Monad (unless)

main :: IO ()
main = do
  args <- getArgs
  let count = if null args then 100000 else read (head args) :: Int
      input = WinInput NoEvent NoEvent (KeyStroke Map.empty) (CtrlData (Map.fromList controls))
#ifdef BARCODE_APP
  runtime <- newBarcodeRuntime
  let network = parseKeyInput >>> combineAll (mkStdGen 42) runtime
      forceOutput (a,b,c,d,e,f,g,h,i,j) = a `seq` b `seq` c `seq` d `seq` e `seq` f `seq` g `seq` h `seq` i `seq` j `seq` ()
#else
  let network = parseKeyInput >>> combineAll (mkStdGen 42)
      forceOutput (a,b,c,d,e,f,g,h,i,j,k) = a `seq` b `seq` c `seq` d `seq` e `seq` f `seq` g `seq` h `seq` i `seq` j `seq` k `seq` ()
#endif
  counter <- newIORef (0 :: Int)
  performGC
  enabled <- getRTSStatsEnabled
  unless enabled (fail "start with +RTS -T -RTS")
  before <- getRTSStats
  cpuStart <- getCPUTime
  start <- getMonotonicTimeNSec
  reactimate (pure input) (\_ -> pure (1/60, Just input))
    (\_ output -> do
      evaluate (forceOutput output)
      atomicModifyIORef' counter (\n -> (n+1,n+1>=count))) network
  finish <- getMonotonicTimeNSec
  cpuEnd <- getCPUTime
  performGC
  after <- getRTSStats
  let wall = fromIntegral (finish-start)/1e9 :: Double
      cpu = fromIntegral (cpuEnd-cpuStart)/1e12 :: Double
      perFrame = cpu*1000/fromIntegral count
  printf "frames=%d wall_s=%.6f cpu_s=%.6f cpu_ms_per_frame=%.6f estimated_cpu_at_60fps=%.3f%% gc_cpu_s=%.6f allocated_MB=%.2f\n"
    count wall cpu perFrame (perFrame*6)
    (fromIntegral (gc_cpu_ns after-gc_cpu_ns before)/1e9 :: Double)
    (fromIntegral (allocated_bytes after-allocated_bytes before)/1e6 :: Double)

controls :: [(String,CtrlItem)]
controls = [
  ("all-configurations-index", CombItem1 0),
  ("barcode-collapse-enabled", PinItem1 False),
  ("barcode-ocr-start", DragItem2 (0,0)),
  ("barcode-ocr-trigger", TrigItem1 Nothing),
  ("barcode-preview-zoom", DragItem1 1),
  ("barcode-printed-text-guard", PinItem1 False),
  ("barcode-region-select", RectItem4 (10,10,300,120)),
  ("barcode-scale-factor", DragItem1 1),
  ("batchocr-state-variable", OcrItem1 OcrUnknown),
  ("camera-param-contrast", DragItem1 1),
  ("camera-param-exposure", DragItem1 1),
  ("camera-param-gamma", DragItem1 1),
  ("camera-param-grain", DragItem1 1),
  ("camera-param-reverse-x", PinItem1 False),
  ("camera-param-reverse-y", PinItem1 False),
  ("camera-param-sharpness", DragItem1 1),
  ("motion-approach-confirmed", PinItem1 False),
  ("motion-collapse-enabled", PinItem1 False),
  ("motion-region-select", RectItem4 (10,10,300,120)),
  ("motion-sense-lag", DragItem1 1),
  ("motion-trigger-threshold", DragItem1 1),
  ("opencv-canny-enable", PinItem1 False),
  ("opencv-canny-threshold1", DragItem1 1),
  ("opencv-canny-threshold2", DragItem1 1),
  ("opengl-camera-parameters", DragItem3 (0,0,1)),
  ("production-ng-count", CombItem1 0),
  ("production-ng-hold", PinItem1 False),
  ("production-ok-count", CombItem1 0),
  ("production-ok-hold", PinItem1 False),
  ("serial-number-collapse-enabled", PinItem1 False),
  ("serial-number-ocr-start", DragItem2 (0,0)),
  ("serial-number-ocr-stochastic-delta", StochItem2 (0,0)),
  ("serial-number-ocr-trigger", TrigItem1 Nothing),
  ("serial-number-plc-modbus-trigger", TrigItem1 Nothing),
  ("serial-number-preview-zoom", DragItem1 1),
  ("serial-number-range-select-active", PinItem1 False),
  ("serial-number-region-select", RectItem4 (10,10,300,120)),
  ("serial-number-scale-factor", DragItem1 1),
  ("serial-number-sequence-marker", CompItem1 Nothing),
  ("trigger-batchocr-operation", PinItem1 False),
  ("trigger-parameters-restore", PinItem1 False)
  ]
