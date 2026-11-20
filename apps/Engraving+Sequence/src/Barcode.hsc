
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}

module Barcode where

import qualified ProductionDebug as PD

import Data.Word
import Data.Char
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

C.include "<cstdlib>"

C.include "modbus.h"
C.include "iostream"

C.include "Barcode/BarcodeRecog.cpp"

C.verbatim [r|
   static int modbusSetting(const char* name, int fallback, int maximum) {
     const char* value = std::getenv(name);
     if (!value || !*value) return fallback;
     char* end = nullptr;
     long parsed = std::strtol(value, &end, 10);
     return (*end == '\0' && parsed > 0 && parsed <= maximum) ? parsed : fallback;
   }
   modbus mb = modbus(std::getenv("SEQUENCE_MODBUS_HOST") ?
     std::getenv("SEQUENCE_MODBUS_HOST") : "192.168.0.68",
     modbusSetting("SEQUENCE_MODBUS_PORT", 4998, 65535));
|]


modbusInit :: IO ()
modbusInit = if PD.debugMode then putStrLn "[调试] Modbus模拟模式：不连接控制器，使用触发modbus按钮" else do
 [CU.block| void {
   // set slave id
   mb.modbus_set_slave_id(modbusSetting("SEQUENCE_MODBUS_SLAVE", 3, 247));
   // connect with the server
   mb.modbus_connect();
 }|]


modbusOk :: IO ()
modbusOk = if PD.debugMode then do
  putStrLn "[调试] 模拟PLC输出 OK（未写入控制器）"
  PD.finishDebugTrigger
 else do
 [CU.block| void {
   mb.modbus_write_register(4, 99);
 }|]


modbusNg :: IO ()
modbusNg = if PD.debugMode then do
  putStrLn "[调试] 模拟PLC输出 NG（未写入控制器）"
  PD.finishDebugTrigger
 else do
 [CU.block| void {
   mb.modbus_write_register(2, 88);
 }|]


modbusTrigger :: IO String
modbusTrigger = if PD.debugMode then do
  triggered <- PD.consumeDebugTrigger
  pure (if triggered then "ok" else "ng")
 else do
  [CU.block| char* {
    uint16_t read_holding_regs[16];
    read_holding_regs[0] = 0;
    mb.modbus_read_holding_registers(0, 1, read_holding_regs);

    std::cout << "modbus_read_holding_registers: " << read_holding_regs[0] << std::endl;

    static std::string nop;
    nop = "ng";

    if(read_holding_regs[0] == 77) {
      nop = "ok";
    }
    return (char*)nop.c_str();

  }|] >>= peekCAString


barcodeRecog :: (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO String
barcodeRecog img = do
  withPtr img $ \imgPtr -> do
    [CU.block| char* {
      stringstream buffer;
      static std::string nop;
      vector<decodedObject> decodedObjects;
      decode((*$(Mat * imgPtr)), decodedObjects);

      nop = "ng";
      if(decodedObjects.size() == 1) {
        buffer << decodedObjects[0].data;
        nop = buffer.str();
      }
      return (char*)nop.c_str();
    }|] >>= peekCAString



procBarcode :: TChan (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> TChan String -> IO ()
procBarcode submit receive = do
  forever $ do
    r <- atomically $ readTChan submit
    renderImage "my2.png" r
    raw <- barcodeRecog r
    print $ "barcode " ++ raw
    atomically $ writeTChan receive (T.unpack (T.filter (\n-> (isNumber n) || (isAlpha n)) $ T.pack raw))
    return ()

