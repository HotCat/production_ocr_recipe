{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}

module Device.Motion.Linuxcnc (getState) where

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
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException )
import OpenCV.TypeLevel

import Linear.V2 (V2(..))
import Linear.V3 ( V3(..) )
import Linear.V4 ( V4(..) )

import Data.Proxy ( Proxy(..) )
import Control.Monad.Trans.Class ( lift )

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import System.IO.Unsafe ( unsafePerformIO )
import qualified Data.Text as T

import qualified Data.ByteString as BS
import Foreign.ForeignPtr ( ForeignPtr, withForeignPtr, castForeignPtr )
import Foreign.Marshal.Array (withArray, allocaArray, mallocArray, peekArray)
import Foreign.C.String ( withCString )
import Control.Monad.Trans.Except

--------------------------------------------------------------------------------

C.context openCvCtx

C.include "<stdlib.h>"

C.include "opencv2/opencv.hpp"

C.include "Linuxcnc/getpins.cpp"

C.using "namespace cv"
C.using "namespace std"
C.using "namespace linuxcnc"

getState :: IO String
getState = do
  [CU.block| char* {
      return getpins();
  }|] >>= peekCAString



