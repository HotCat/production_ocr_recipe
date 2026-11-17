
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}

module Barcode where

import Data.Word
import Data.Char
import BarcodeGuard
import TextRecog (prepareOcr, predictOcr)
import qualified Control.Exception as E
import Control.Concurrent.Async (Async, async, poll)
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Foreign.Ptr (nullPtr)
import Foreign.Marshal.Alloc (free)
import qualified Data.Text.Encoding as TE
import Foreign.C.Types
import Foreign.C.String
import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU
import qualified Language.C.Inline.Cpp as C
import qualified Data.ByteString as B

import OpenCV
import OpenCV.Core.Types
import OpenCV.Internal
import OpenCV.Internal.C.Inline ( openCvCtx )
import OpenCV.Internal.C.Types
import OpenCV.Internal.Core.ArrayOps
import OpenCV.Internal.Core.Types ( withArrayPtr, Scalar )
import OpenCV.Internal.Core.Types.Mat
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException )
import OpenCV.TypeLevel

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import Language.Scheme.Types
import qualified Data.Text as T
import Text.RawString.QQ

C.context openCvCtx

C.include "<stdlib.h>"

C.include "modbus.h"
C.include "iostream"
C.include "<cstring>"
C.include "<stdexcept>"

C.include "Barcode/BarcodeRecog.cpp"

C.verbatim [r|
   modbus mb = modbus("192.168.0.68", 4998);
|]


modbusInit :: IO ()
modbusInit = do
 [CU.block| void {
   // set slave id
   mb.modbus_set_slave_id(3);
   // connect with the server
   mb.modbus_connect();
 }|]


modbusOk :: IO ()
modbusOk = do
 [CU.block| void {
   mb.modbus_write_register(4, 99);
 }|]


modbusNg :: IO ()
modbusNg = do
 [CU.block| void {
   mb.modbus_write_register(2, 88);
 }|]


-- Read the trigger independently from decoding, so the same captured label
-- can be inspected once without blocking the GUI on OCR.
modbusTriggered :: IO Bool
modbusTriggered = (/= 0) <$> [C.block| int {
  uint16_t registers[1] = {0};
  mb.modbus_read_holding_registers(0, 1, registers);
  return registers[0] == 77 ? 1 : 0;
}|]

modbusTrigger :: Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> IO String
modbusTrigger image = do
  triggered <- modbusTriggered
  if triggered then barcodeRecog image else pure "ng"

-- Process-wide inspection policy: one checkbox/configuration is shared by the
-- evaluation workers and PLC inspection. Each request snapshots it before OCR.
{-# NOINLINE barcodeGuardPolicy #-}
barcodeGuardPolicy :: TVar Bool
barcodeGuardPolicy = unsafePerformIO (newTVarIO False)

setBarcodeGuardEnabled :: Bool -> IO ()
setBarcodeGuardEnabled = atomically . writeTVar barcodeGuardPolicy

getBarcodeGuardEnabled :: IO Bool
getBarcodeGuardEnabled = readTVarIO barcodeGuardPolicy

-- ZBar-only decode is used for the live selection/trigger preview. It owns its
-- response buffer; two workers never race over a static C++ string.
decodeBarcode :: Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> IO String
decodeBarcode image = do
  let request = withPtr image $ \imagePtr -> [C.block| char* {
        std::string response = "ng";
        try {
          const cv::Mat& source = *$(Mat * imagePtr);
          if (!source.empty()) {
            std::vector<decodedObject> objects;
            cv::Mat view = source;
            decode(view, objects);
            if (objects.size() == 1) response = objects[0].data;
          }
        } catch (const std::exception& error) {
          response = std::string("ERROR: ") + error.what();
        }
        char* output = static_cast<char*>(std::malloc(response.size() + 1));
        if (output) std::memcpy(output, response.c_str(), response.size() + 1);
        return output;
      }|]
  E.bracket request free $ \result -> do
    when (result == nullPtr) $ ioError (userError "ZBar response allocation failed")
    bytes <- B.packCString result
    text <- either E.throwIO pure (TE.decodeUtf8' bytes)
    let decoded = T.unpack text
    if take 6 decoded == "ERROR:"
      then ioError (userError decoded)
      else pure decoded

-- Public compatibility API now honors the guard; rejected labels return "ng".
-- Diagnostic callers use inspectBarcode to retain the reason for rejection.
barcodeRecog :: Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> IO String
barcodeRecog image = do
  enabled <- getBarcodeGuardEnabled
  result <- inspectBarcode enabled image
  pure $ if guardAllowsResult enabled result then barcodeDecoded result else "ng"

tryBarcodeIO :: IO a -> IO (Either String a)
tryBarcodeIO action = E.catch (Right <$> action) $ \failure ->
  case E.fromException failure :: Maybe E.AsyncException of
    Just _ -> E.throwIO (failure :: E.SomeException)
    Nothing -> pure (Left (E.displayException (failure :: E.SomeException)))

-- Testable at the real decision boundary; OCR is never invoked in barcode-only
-- mode, and is never allowed to turn a decode failure into an accepted label.
inspectBarcodeWith :: (image -> IO String) -> (image -> IO String)
                   -> Bool -> image -> IO BarcodeResult
inspectBarcodeWith decodeImage recognizeText enabled image = do
  decoded <- tryBarcodeIO (decodeImage image)
  case decoded of
    Left failure -> pure (BarcodeResult enabled BarcodeReadError "" "" failure)
    Right value
      | not enabled || value == "ng" || null value ->
          pure (validateBarcode enabled value (Right ""))
      | otherwise -> validateBarcode enabled value <$> tryBarcodeIO (recognizeText image)

inspectBarcode :: Bool -> Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> IO BarcodeResult
inspectBarcode = inspectBarcodeWith decodeBarcode (\image -> prepareOcr >>= predictOcr image)

-- Every submitted label produces exactly one complete diagnostic on its own
-- result channel. No filtering strips punctuation or hides mismatches/errors.
-- A failed service request does not terminate this worker.
procBarcode :: TChan (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> TChan String -> IO ()
procBarcode = procBarcodeWith inspectBarcode getBarcodeGuardEnabled

procBarcodeWith :: (Bool -> image -> IO BarcodeResult) -> IO Bool
                -> TChan image -> TChan String -> IO ()
procBarcodeWith inspect policy submit receive = forever $ do
  image <- atomically $ readTChan submit
  enabled <- policy
  outcome <- tryBarcodeIO (inspect enabled image)
  let result = either (BarcodeResult enabled BarcodeReadError "" "") id outcome
      message = formatBarcodeResult result
  atomically $ writeTChan receive message
  putStr message

-- Only one PLC inspection may be in flight. The GUI polls it instead of waiting
-- for the shared OCR service, and latches a label while register 0 remains 77.
data BarcodeRuntime = BarcodeRuntime
  { barcodePending :: IORef (Maybe (Async BarcodeResult))
  , barcodeLastLabel :: IORef (Maybe String)
  , barcodeProductionBusy :: IORef Bool
  }

newBarcodeRuntime :: IO BarcodeRuntime
newBarcodeRuntime = BarcodeRuntime <$> newIORef Nothing <*> newIORef Nothing <*> newIORef False

pollBarcodeInspection :: BarcodeRuntime -> IO (Maybe BarcodeResult)
pollBarcodeInspection runtime = do
  pending <- readIORef (barcodePending runtime)
  case pending of
    Nothing -> pure Nothing
    Just task -> do
      outcome <- poll task
      case outcome of
        Nothing -> pure Nothing
        Just (Right result) -> writeIORef (barcodePending runtime) Nothing >> pure (Just result)
        Just (Left failure) -> do
          writeIORef (barcodePending runtime) Nothing
          enabled <- getBarcodeGuardEnabled
          pure (Just (BarcodeResult enabled BarcodeReadError "" "" (E.displayException failure)))

queueBarcodeInspection :: BarcodeRuntime -> Bool -> Bool -> String
                       -> Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> IO ()
queueBarcodeInspection = queueBarcodeInspectionWith inspectBarcode

queueBarcodeInspectionWith :: (Bool -> image -> IO BarcodeResult)
                           -> BarcodeRuntime -> Bool -> Bool -> String -> image -> IO ()
queueBarcodeInspectionWith inspect runtime enabled triggered decoded image = do
  let label = if triggered && decoded /= "ng" && not (null decoded)
                then Just decoded else Nothing
  previous <- readIORef (barcodeLastLabel runtime)
  pending <- readIORef (barcodePending runtime)
  busy <- isBarcodeProductionBusy runtime
  if busy then
    when (label == Nothing) $ writeIORef (barcodeLastLabel runtime) Nothing
  else case pending of
    Just _ -> when (label == Nothing) $ writeIORef (barcodeLastLabel runtime) Nothing
    Nothing -> do
      writeIORef (barcodeLastLabel runtime) label
      when (label /= Nothing && label /= previous) $ do
        task <- async (inspect enabled image)
        writeIORef (barcodePending runtime) (Just task)

-- Setting changes invalidate the latch, so the current label is inspected again
-- under the new setting. An older unguarded result is rejected by decideProduction.
resetBarcodeInspection :: BarcodeRuntime -> IO ()
resetBarcodeInspection runtime = writeIORef (barcodeLastLabel runtime) Nothing

-- The combined application keeps ownership of the current label until its
-- engraving check finishes. Later labels must not overwrite that inspection.
setBarcodeProductionBusy :: BarcodeRuntime -> Bool -> IO ()
setBarcodeProductionBusy runtime = writeIORef (barcodeProductionBusy runtime)

isBarcodeProductionBusy :: BarcodeRuntime -> IO Bool
isBarcodeProductionBusy = readIORef . barcodeProductionBusy
