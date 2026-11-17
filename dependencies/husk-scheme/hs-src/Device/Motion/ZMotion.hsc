
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

module Device.Motion.ZMotion (ModbusZv, zm_connect, zm_close, zm_getFloat, zm_setFloat, zm_setBit, zm_getBit) where

import Foreign.C.Types
import Foreign.C.String
import Data.Int
import Data.Word
import Data.Char
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
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException, wrapException )
import OpenCV.TypeLevel
import OpenCV.Internal.C.FinalizerTH

import Linear.V2 (V2(..))
import Linear.V3 ( V3(..) )
import Linear.V4 ( V4(..) )

import Data.Proxy ( Proxy(..) )
import Control.Monad.Trans.Class ( lift )

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Text as T

import qualified Data.ByteString as BS
import Foreign.ForeignPtr ( ForeignPtr, withForeignPtr, castForeignPtr )
import Foreign.Marshal.Array (withArray, allocaArray, mallocArray, peekArray)
import Foreign.C.String ( withCString )
import Control.Monad.Trans.Except

import Control.Monad.IO.Class ( MonadIO, liftIO )
import Control.Monad.Error.Class ( MonadError )

--------------------------------------------------------------------------------

C.context openCvCtx

C.include "<stdlib.h>"

C.include "opencv2/opencv.hpp"
C.include "ZMotion/zmcaux.cpp"
C.include "ZMotion/Motion.cpp"
C.include "zmotion.hpp"

C.using "namespace cv"
C.using "namespace std"

newtype ModbusZv = ModbusZv {unModbusZv :: ForeignPtr C'Ptr_ModbusZv}

type instance C ModbusZv = C'Ptr_ModbusZv

instance WithPtr ModbusZv where
  withPtr = withForeignPtr . unModbusZv

mkFinalizer DeletePtr "deleteModbusZv" "Ptr_ModbusZv" ''C'Ptr_ModbusZv

-- instance FromPtr ModbusZv where
--   fromPtr = objFromPtr ModbusZv $ \ptr ->
--     [CU.block| void {
--         cv::Ptr<ModbusZ> * zv_ptr_ptr = $(Ptr_ModbusZv * ptr);
--         zv_ptr_ptr->release();
--         delete zv_ptr_ptr;
--     }|]

instance FromPtr ModbusZv where
  fromPtr = objFromPtr ModbusZv deleteModbusZv

newEmptyBusPtr :: IO ModbusZv
newEmptyBusPtr = fromPtr [CU.exp|Ptr_ModbusZv * {new cv::Ptr<ModbusZ>()}|]

zm_connect :: (MonadIO m, MonadError CvException m) => String -> m ModbusZv
zm_connect ipAddr = wrapException $ liftIO $ withCString ipAddr $ \ipAddrPtr -> do
  mybus <- newEmptyBusPtr
  withPtr mybus $ \myBusPtr -> do
    handleCvException (pure $ mybus) $
      [cvExcept|
        ModbusZ modbus($(char* ipAddrPtr));
        std::cout << "zm_connect success" << std::endl;

        cv::Ptr<ModbusZ> busPtr = cv::makePtr<ModbusZ>(modbus);
        *$(Ptr_ModbusZv * myBusPtr) = busPtr;
      |]


zm_close :: (MonadIO m, MonadError CvException m) => ModbusZv -> m ()
zm_close bus = wrapException $ liftIO $ do
  withPtr bus $ \busPtr ->
    handleCvException (pure ()) $
      [cvExcept|
        (**$(Ptr_ModbusZv * busPtr)).closeZ();
      |]


zm_getBit :: (MonadIO m, MonadError CvException m) => ModbusZv -> Int -> Int -> m [Bool]
zm_getBit bus start inum = wrapException $ liftIO $ do
  withPtr bus $ \busPtr ->
    allocaArray inum $ \arrayPtr -> do
      handleCvException ((map (\x->if x == 0 then False else True)) <$> peekArray inum arrayPtr) $
        [cvExcept|
          (**$(Ptr_ModbusZv * busPtr)).getBit($(int start'), $(int inum'), $(unsigned char * arrayPtr));
        |]
   where
     inum' = fromIntegral inum
     start' = fromIntegral start


zm_setBit :: (MonadIO m, MonadError CvException m) => ModbusZv -> [Bool] -> Int -> Int -> m ()
zm_setBit bus input start inum = wrapException $ liftIO $ do
  let bs = B.pack $ map (\b->if b then 1 else 0) input
  withPtr bus $ \busPtr ->
    handleCvException (pure ()) $
      [cvExcept|
        (**$(Ptr_ModbusZv * busPtr)).setBit($(int start'), $(int inum'), (uint8*)$bs-ptr:bs);
      |]
   where
     inum' = fromIntegral inum
     start' = fromIntegral start


zm_getFloat :: (MonadIO m, MonadError CvException m) => ModbusZv -> Int -> Int -> m [Float]
zm_getFloat bus start inum = wrapException $ liftIO $ do
  withPtr bus $ \busPtr ->
    allocaArray inum $ \arrayPtr -> do
      handleCvException ((map realToFrac) <$> peekArray inum arrayPtr) $
        [cvExcept|
          (**$(Ptr_ModbusZv * busPtr)).getFloat($(int start'), $(int inum'), $(float * arrayPtr));
        |]
   where
     inum' = fromIntegral inum
     start' = fromIntegral start


zm_setFloat :: (MonadIO m, MonadError CvException m) => ModbusZv -> [Float] -> Int -> Int -> m ()
zm_setFloat bus input start inum = wrapException $ liftIO $ do
  withPtr bus $ \busPtr ->
    withArray (map realToFrac input) $ \arrayPtr -> do
      handleCvException (pure ()) $
        [cvExcept|
          (**$(Ptr_ModbusZv * busPtr)).setFloat($(int start'), $(int inum'), $(float * arrayPtr));
        |]
   where
     inum' = fromIntegral inum
     start' = fromIntegral start


initCard :: IO ()
initCard = do
  [C.block| void {
      int ok;
      ZMC_HANDLE handle;
      ok = ZAux_OpenEth("192.168.0.11", &handle);
      std::cout << "connect motion card failed! " << ok << std::endl;

      // uint8 my;
      // my = 1;
      // ok = ZAux_Modbus_Set0x(handle, 0x0032, 1, &my);
      // std::cout << "ZAux_Modbus_Set0x " << ok << std::endl;


      //float my2[3];
      //my2[0] = 3.145;
      //my2[1] = 5.23;
      //my2[2] = -10.23;
      //ok = ZMC_Modbus_SetIEEE(handle, 0x00c8, 3, my2);
      //std::cout << "ZMC_Modbus_SetIEEE " << ok << std::endl;


      //float my2[3];
      //my2[0] = 654.43;
      //ok = ZMC_Modbus_SetIEEE(handle, 0x00ca, 1, my2);
      //std::cout << "ZMC_Modbus_SetIEEE " << ok << std::endl;


      float my3[6];
      ok = ZMC_Modbus_GetIEEE(handle, 0x00c8, 6, my3);
      std::cout << "my3[0] " << my3[0] << std::endl;
      std::cout << "my3[1] " << my3[1] << std::endl;
      std::cout << "my3[2] " << my3[2] << std::endl;
      std::cout << "my3[3] " << my3[3] << std::endl;
      std::cout << "my3[4] " << my3[4] << std::endl;
      std::cout << "my3[5] " << my3[5] << std::endl;
      
  }|]




