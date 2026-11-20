{-# LANGUAGE DataKinds #-}
module Main where

import Barcode
import BarcodeGuard
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (bracket, throwIO)
import Control.Monad
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.ByteString as BS
import qualified OpenCV as CV
import OpenCV.Internal.Core.Types.Mat (unsafeCoerceMat)
import System.Environment (getArgs)
import System.Timeout (timeout)
import FRP.Yampa (embed, deltaEncode, Event(..))

assert :: String -> Bool -> IO ()
assert name value = unless value (fail name)

within :: String -> IO a -> IO a
within name action = timeout 3000000 action >>= maybe (fail (name ++ " timed out")) pure

waitResult :: BarcodeRuntime -> IO BarcodeResult
waitResult runtime = within "inspection result" loop
  where
    loop = pollBarcodeInspection runtime >>= maybe (threadDelay 1000 >> loop) pure

main :: IO ()
main = do
  let matched = validateBarcode True "AB-0012" (Right " AB-0012\n")
      mismatch = validateBarcode True "AB-0012" (Right "AB-0013")
      unguarded = validateBarcode False "AB-0012" (Left "must not matter")
      expected = Just ("0012", 3, 7)
  assert "exact match" (barcodeVerdict matched == BarcodeAccepted)
  assert "whitespace-only normalization" (barcodeVerdict
    (validateBarcode True "AB-0012" (Right "AB0012")) == BarcodeMismatch)
  assert "case sensitivity" (barcodeVerdict
    (validateBarcode True "AB-0012" (Right "ab-0012")) == BarcodeMismatch)
  assert "substring with surrounding text accepted" (barcodeVerdict
    (validateBarcode True "123456" (Right "X123456Y")) == BarcodeAccepted)
  assert "prefix and suffix plus OCR whitespace accepted" (barcodeVerdict
    (validateBarcode True "AB-0012" (Right "Vendor: AB-00 12\n Lot 42")) == BarcodeAccepted)
  assert "partial decoded value is insufficient" (barcodeVerdict
    (validateBarcode True "123456" (Right "12345")) == BarcodeMismatch)
  assert "substring direction is decoded-in-OCR" (barcodeVerdict
    (validateBarcode True "1234567" (Right "123456")) == BarcodeMismatch)
  assert "empty print rejected" (barcodeVerdict
    (validateBarcode True "123456" (Right " \n")) == BarcodeMissingText)
  assert "no unique code rejected" (barcodeVerdict
    (validateBarcode False "ng" (Right "123456")) == BarcodeMissingCode)
  assert "guard success still checks continuity" (decideProduction True expected matched == SequenceMatched)
  assert "wrong expected sequence rejected" (decideProduction True (Just ("0013",3,7)) matched == SequenceMismatched)
  assert "reverse selection works" (decideProduction True (Just ("0012",7,3)) matched == SequenceMatched)
  assert "guard off keeps continuity" (decideProduction False expected unguarded == SequenceMatched)
  assert "mismatch blocks sequence advance" (case decideProduction True expected mismatch of
    ProductionRejected _ -> True; _ -> False)
  assert "failure rejected even without configured sequence" (case decideProduction True Nothing mismatch of
    ProductionRejected _ -> True; _ -> False)
  assert "stale unguarded result blocked" (case decideProduction True expected unguarded of
    ProductionRejected _ -> True; _ -> False)
  assert "accepted result without sequence does not count" (decideProduction True Nothing matched == SequenceUnconfigured)
  assert "typed trigger round trip" ((read (show matched) :: BarcodeResult) == matched)
  let completions = embed inspectionCompletions (deltaEncode 0.01
        [Nothing, Just matched, Just matched, Just mismatch, Nothing, Just matched])
  assert "completion events never drop a fast mismatch or duplicate a held result"
    (completions == [NoEvent, Event matched, NoEvent, Event mismatch, NoEvent, Event matched])
  putStrLn "PASS: substring comparison, fail-closed verdicts and continuity decisions"

  debugRuntime <- newBarcodeRuntime
  let debugInspect enabled _ = pure (validateBarcode enabled "AB-0012" (Right "AB-0012"))
  forM_ [1..2 :: Int] $ \_ -> do
    queueDebugBarcodeInspectionWith debugInspect debugRuntime True True (Right ())
    outcome <- waitResult debugRuntime
    assert "each debug click inspects identical labels again" (barcodeVerdict outcome == BarcodeAccepted)
    pollBarcodeInspection debugRuntime >>= assert "one completion per debug click" . (== Nothing)
  queueDebugBarcodeInspectionWith debugInspect debugRuntime True True (Left "invalid ROI")
  invalid <- waitResult debugRuntime
  assert "invalid debug ROI completes as NG" (barcodeVerdict invalid == BarcodeReadError)
  putStrLn "PASS: debug clicks repeat identical labels and complete invalid ROI as NG"

  ocrCalls <- newIORef (0 :: Int)
  let decode _ = pure "AB-0012"
      ocr _ = modifyIORef' ocrCalls (+1) >> pure "AB-0012"
  _ <- inspectBarcodeWith decode ocr False ()
  count <- readIORef ocrCalls
  assert "disabled guard must not call service" (count == 0)
  _ <- inspectBarcodeWith decode ocr True ()
  count2 <- readIORef ocrCalls
  assert "enabled guard calls service" (count2 == 1)
  failed <- inspectBarcodeWith decode (\_ -> throwIO (userError "service unavailable")) True ()
  assert "service error rejected" (barcodeVerdict failed == BarcodeReadError)
  putStrLn "PASS: no OCR when disabled; service failures become rejected results"

  submit <- newTChanIO
  receive <- newTChanIO
  policy <- newTVarIO False
  let inspector enabled number = inspectBarcodeWith (\_ -> pure "123456")
        (\n -> case n of
          0 -> pure "123456"
          1 -> pure "654321"
          2 -> pure ""
          3 -> fail "test service failure"
          _ -> pure "123456") enabled number
      getMessage value = do
        atomically $ writeTChan submit (value :: Int)
        within "worker diagnostic" (atomically $ readTChan receive)
  bracket (forkIO (procBarcodeWith inspector (readTVarIO policy) submit receive)) killThread $ \_ -> do
    off <- getMessage 0
    assert "off log" ("印字校验关闭" `isInfixOf` off && "BARCODE ONLY" `isInfixOf` off)
    atomically $ writeTVar policy True
    good <- getMessage 0
    bad <- getMessage 1
    missing <- getMessage 2
    errorMessage <- getMessage 3
    recovered <- getMessage 0
    assert "match log" ("MATCH" `isInfixOf` good && "印字校验开启" `isInfixOf` good)
    assert "both values in mismatch log" (all (`isInfixOf` bad) ["MISMATCH","123456","654321"])
    assert "missing text log" ("NO TEXT" `isInfixOf` missing)
    assert "error log" ("OCR ERROR" `isInfixOf` errorMessage)
    assert "worker survives exception" ("MATCH" `isInfixOf` recovered)
    remaining <- atomically $ tryReadTChan receive
    assert "one diagnostic per request" (remaining == Nothing)
  putStrLn "PASS: TChan diagnostics, live setting changes and recovery after OCR failure"

  runtime <- newBarcodeRuntime
  entered <- newEmptyMVar
  release <- newEmptyMVar
  invocations <- newIORef (0 :: Int)
  let slow enabled _ = do
        modifyIORef' invocations (+1)
        putMVar entered ()
        takeMVar release
        pure (validateBarcode enabled "123456" (Right "123456"))
  within "nonblocking enqueue" $ queueBarcodeInspectionWith slow runtime True True "123456" ()
  within "worker start" $ takeMVar entered
  queueBarcodeInspectionWith slow runtime True True "123456" ()
  active <- readIORef invocations
  assert "at most one in-flight request" (active == 1)
  pending <- pollBarcodeInspection runtime
  assert "nonblocking poll" (pending == Nothing)
  putMVar release ()
  completed <- waitResult runtime
  assert "async completed" (barcodeVerdict completed == BarcodeAccepted)
  queueBarcodeInspectionWith slow runtime True True "123456" ()
  after <- readIORef invocations
  assert "held PLC trigger not duplicated" (after == 1)
  queueBarcodeInspectionWith slow runtime True False "ng" ()
  queueBarcodeInspectionWith slow runtime True True "123456" ()
  within "rearmed worker" $ takeMVar entered
  putMVar release ()
  _ <- waitResult runtime
  putStrLn "PASS: asynchronous inspection, held-trigger latch, and rearming"

  -- A second barcode must not overwrite the accepted inspection while the
  -- combined application's engraving stage still owns it.
  setBarcodeProductionBusy runtime True
  busy <- isBarcodeProductionBusy runtime
  assert "engraving owns production" busy
  queueBarcodeInspectionWith slow runtime True False "ng" ()
  queueBarcodeInspectionWith slow runtime True True "654321" ()
  blocked <- pollBarcodeInspection runtime
  activeWhileBusy <- readIORef invocations
  assert "no barcode starts during engraving" (blocked == Nothing && activeWhileBusy == 2)
  setBarcodeProductionBusy runtime False
  queueBarcodeInspectionWith slow runtime True True "654321" ()
  within "next barcode after engraving" $ takeMVar entered
  putMVar release ()
  _ <- waitResult runtime
  afterEngraving <- readIORef invocations
  assert "next barcode starts after engraving releases ownership" (afterEngraving == 3)
  putStrLn "PASS: engraving stage ownership prevents barcode result replacement"

  args <- getArgs
  case args of
    [] -> pure ()
    [directory] -> do
      let load name = unsafeCoerceMat . CV.imdecode CV.ImreadColor <$>
            BS.readFile (directory ++ "/" ++ name ++ ".png")
      matching <- load "match"
      wrong <- load "mismatch"
      blank <- load "no-barcode"
      multiple <- load "multiple"
      raw <- decodeBarcode matching
      assert "real ZBar decode" (raw == "123456")
      none <- decodeBarcode blank
      many <- decodeBarcode multiple
      assert "zero/multiple codes rejected" (none == "ng" && many == "ng")
      setBarcodeGuardEnabled False
      oldResult <- barcodeRecog wrong
      assert "public API guard off" (oldResult == "123456")
      setBarcodeGuardEnabled True
      good <- barcodeRecog matching
      bad <- barcodeRecog wrong
      assert ("public API matching label: " ++ show good) (good == "123456")
      assert "public API wrong print" (bad == "ng")
      putStrLn "PASS: real ZBar/PaddleOCR and barcodeRecog API, including vendor misprint"
    _ -> fail "Usage: BarcodeGuardSpec [fixture-directory]"
