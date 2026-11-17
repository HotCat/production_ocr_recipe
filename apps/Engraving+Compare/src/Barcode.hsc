
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}

module Barcode where

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



C.verbatim [r|
   static int modbusSetting(const char* name, int fallback, int maximum) {
     const char* value = std::getenv(name);
     if (!value || !*value) return fallback;
     char* end = nullptr;
     long parsed = std::strtol(value, &end, 10);
     return (*end == '\0' && parsed > 0 && parsed <= maximum) ? parsed : fallback;
   }
   static modbus* mb = nullptr;
|]


modbusInit :: IO ()
modbusInit = do
 [C.block| void {
   if (!mb) mb = new modbus(std::getenv("ENGRAVING_COMPARE_MODBUS_HOST") ?
     std::getenv("ENGRAVING_COMPARE_MODBUS_HOST") : "192.168.0.68",
     modbusSetting("ENGRAVING_COMPARE_MODBUS_PORT", 4998, 65535));
   // set slave id
   mb->modbus_set_slave_id(modbusSetting("ENGRAVING_COMPARE_MODBUS_SLAVE", 3, 247));
   // connect with the server
   mb->modbus_connect();
 }|]


modbusOk :: IO ()
modbusOk = do
 [C.block| void {
   mb->modbus_write_register(4, 99);
 }|]


modbusNg :: IO ()
modbusNg = do
 [C.block| void {
   mb->modbus_write_register(2, 88);
 }|]


modbusTrigger :: IO String
modbusTrigger = do
  [C.block| char* {
    uint16_t read_holding_regs[16];
    read_holding_regs[0] = 0;
    mb->modbus_read_holding_registers(0, 1, read_holding_regs);



    static std::string nop;
    nop = "ng";

    if(read_holding_regs[0] == 77) {
      nop = "ok";
    }
    return (char*)nop.c_str();

  }|] >>= peekCAString


