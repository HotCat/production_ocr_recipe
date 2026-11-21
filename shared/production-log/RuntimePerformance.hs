-- OpenCV owns a native worker pool independent of GHC's RTS capabilities.
-- Configure it before camera capture or any Haskell OCR workers start.
module RuntimePerformance
  ( Performance, initializeRuntime, measure, endFrame ) where

import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.List (sortOn)
import Data.Ord (Down(..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumCapabilities)
import GHC.Stats
import qualified OpenCV as CV
import System.CPUTime (getCPUTime)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import Text.Read (readMaybe)
import Data.Word (Word64)

-- Nothing is the normal fast path: no clocks, map updates or periodic output.
-- Timings are wall times and may include camera/PLC/driver waits. The script
-- bucket includes nested barcode/serial/motion buckets; do not sum them.
type Performance = Maybe (IORef Sample)
data Sample = Sample
  { started :: !Word64, cpuStarted :: !Integer, gcStarted :: !Word64
  , frames :: !Int, phases :: !(Map.Map String (Int, Word64)) }

initializeRuntime :: IO Performance
initializeRuntime = do
  setting <- lookupEnv "OCR_OPENCV_THREADS"
  case setting of
    Just "auto" -> CV.setNumThreads (-1)
    _ -> do
      let selected = maybe (Just 1) readMaybe setting :: Maybe Int
      case selected of
        Just n | n >= 1 && n <= 16 -> CV.setNumThreads (fromIntegral n)
        _ -> ioError (userError "OCR_OPENCV_THREADS must be 1..16 or auto")
  threads <- CV.getNumThreads
  caps <- getNumCapabilities
  hPutStrLn stderr (printf "[runtime] Haskell capabilities=%d; OpenCV threads=%d" caps threads)
  enabled <- (== Just "1") <$> lookupEnv "OCR_CPU_PROFILE"
  if not enabled then pure Nothing else do
    available <- getRTSStatsEnabled
    unless available $ hPutStrLn stderr "[cpu-profile] GC stats unavailable; start with +RTS -T -RTS"
    now <- getMonotonicTimeNSec
    cpu <- getCPUTime
    gc <- currentGcCpu
    Just <$> newIORef (Sample now cpu gc 0 Map.empty)

currentGcCpu :: IO Word64
currentGcCpu = do
  enabled <- getRTSStatsEnabled
  if enabled then fromIntegral . gc_cpu_ns <$> getRTSStats else pure 0

measure :: Performance -> String -> IO a -> IO a
measure Nothing _ action = action
measure (Just ref) name action = bracket getMonotonicTimeNSec (\begin -> do
  end <- getMonotonicTimeNSec
  atomicModifyIORef' ref $ \sample ->
    (sample { phases = Map.insertWith (\(n,t) (n0,t0) -> (n+n0,t+t0))
      name (1, end-begin) (phases sample) }, ())) (const action)

endFrame :: Performance -> IO ()
endFrame Nothing = pure ()
endFrame (Just ref) = do
  modifyIORef' ref $ \sample -> sample { frames = frames sample + 1 }
  sample <- readIORef ref
  now <- getMonotonicTimeNSec
  when (now - started sample >= 5000000000) $ do
    cpu <- getCPUTime
    gc <- currentGcCpu
    let wall = fromIntegral (now - started sample) / 1e9 :: Double
        cpuSeconds = fromIntegral (cpu - cpuStarted sample) / 1e12 :: Double
        gcSeconds = fromIntegral (gc - gcStarted sample) / 1e9 :: Double
        details :: String
        details = concatMap (\(name,(n,t)) -> printf " %s=%.3fms/%d" name
          (fromIntegral t / 1e6 / fromIntegral (max 1 n) :: Double) n)
          (sortOn (Down . snd . snd) (Map.toList (phases sample)))
    hPutStrLn stderr $ printf "[cpu-profile] frames=%d fps=%.1f process=%.1f%% gc_cpu=%.3fs/%.3fs%s"
      (frames sample) (fromIntegral (frames sample) / wall) (100 * cpuSeconds / wall)
      gcSeconds cpuSeconds details
    writeIORef ref (Sample now cpu gc 0 Map.empty)
