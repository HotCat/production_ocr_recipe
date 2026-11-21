-- Request timing belongs in the client's stderr, captured by the launcher's
-- runtime log. The plain-text OCR service protocol remains unchanged.
module OcrTiming (timeOcrRequest) where

import Control.Exception
import qualified Data.ByteString.Char8 as BS
import GHC.Clock (getMonotonicTimeNSec)
import System.IO (hFlush, stderr)
import Text.Printf (printf)

-- Measure wall time, including PNG encoding, queue/network waits and inference.
-- Preserve the response and every exception, including worker cancellation.
timeOcrRequest :: IO String -> IO String
timeOcrRequest action = mask $ \restore -> do
  start <- getMonotonicTimeNSec
  outcome <- try (restore action) :: IO (Either SomeException String)
  finish <- getMonotonicTimeNSec
  let elapsedMs = fromIntegral (finish - start) / 1e6 :: Double
      status = case outcome of
        Right "" -> "EMPTY"
        Right _ -> "OK"
        Left failure -> case fromException failure :: Maybe SomeAsyncException of
          Just _ -> "CANCELLED"
          Nothing -> "ERROR"
      message = printf "[PaddleOCR] status=%s request_ms=%.3f\n" status elapsedMs
  -- Write the whole ASCII line together. A logging IO error must not turn a
  -- successful recognition into NG or hide the original request exception.
  _ <- try (BS.hPut stderr (BS.pack message) >> hFlush stderr) :: IO (Either IOException ())
  either throwIO pure outcome
