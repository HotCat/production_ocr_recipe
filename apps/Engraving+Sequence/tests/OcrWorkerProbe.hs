{-# LANGUAGE DataKinds #-}
module Main where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import qualified OpenCV as CV
import OpenCV.Internal.Core.Types.Mat (unsafeCoerceMat)
import System.Environment (getArgs)
import System.Timeout (timeout)
import TextRecog

-- Exercise the exact background worker used by the GUI's 评估 button.
-- Runs from a temporary directory with no 1/ debug-output directory.
main :: IO ()
main = do
  [path, count] <- getArgs
  encoded <- BS.readFile path
  let image = unsafeCoerceMat (CV.imdecode CV.ImreadColor encoded)
  ocr <- prepareOcr
  submit <- newTChanIO
  receive <- newTChanIO
  finished <- newEmptyMVar
  bracket (forkFinally (procSerialNum ocr submit receive) (putMVar finished)) killThread $ \_ -> do
    forM_ [1..read count :: Int] $ \_ -> do
      atomically $ writeTChan submit image
      reply <- timeout 10000000 (atomically $ readTChan receive)
      case reply of
        Nothing -> throwIO (userError "OCR preview worker did not reply")
        Just value -> putStr value
  stopped <- timeout 1000000 (takeMVar finished)
  unless (maybe False (const True) stopped) $
    throwIO (userError "OCR worker swallowed cancellation")
