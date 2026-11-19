
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

module Device.Camera.Hikvision (CameraHv, hv_init, hv_close, hv_readFrame, hv_setProperties) where

import qualified OpenCV
import OpenCV.TypeLevel
import OpenCV.VideoIO.Types
import Data.Monoid ( (<>) )
import Data.Proxy
import Data.Traversable
import Data.Word
import Foreign.C.Types ( CFloat )
import GHC.TypeLits
import System.IO.Unsafe ( unsafePerformIO )
import Data.Default
import Codec.Picture
import Linear.Metric as Linear ( norm )
import Linear ( M33 )
import Linear.Vector ( (^+^), (^-^) )
import Linear.V2 ( V2(..) )
import Linear.V3 ( V3(..) )
import Linear.V4 ( V4(..) )
import OpenCV
import OpenCV.Juicy
import OpenCV.Unsafe

import OpenCV.Core.Types
import OpenCV.Internal.C.Inline ( openCvCtx )
import OpenCV.Internal.Core.Types
import OpenCV.Internal.C.Types
import OpenCV.Internal.Core.Types.Mat
import OpenCV.Internal.C.FinalizerTH
import OpenCV.TypeLevel
import System.IO.Unsafe ( unsafePerformIO )


import Control.Monad.Primitive ( PrimMonad, PrimState )
import qualified Data.Text as T
import qualified Data.Vector as V
import Control.Monad.Trans.Class ( lift )


import Data.Functor ( void )
import Data.Foldable ( forM_ )
import Data.Int


import Data.Time
import GHC.Conc (numCapabilities)

import qualified Control.Monad.Parallel as P
import Control.Parallel.Strategies hiding (parMap)
import Control.Exception
import Control.DeepSeq
import Control.Concurrent
import Control.Concurrent.Async
import Text.Printf
import Language.Haskell.TH.Syntax (addDependentFile)
import qualified Data.ByteString as B

import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU
import qualified Language.C.Inline.Cpp as C

import OpenCV.Core.Types
import OpenCV.Internal
import OpenCV.Internal.C.Inline ( openCvCtx )
import OpenCV.Internal.C.Types
import OpenCV.Internal.Core.ArrayOps
import OpenCV.Internal.Core.Types ( withArrayPtr, Scalar )
import OpenCV.Internal.Core.Types.Mat
import OpenCV.Internal.Exception ( CvException, cvExcept, cvExceptU, unsafeWrapException, handleCvException )
import OpenCV.TypeLevel
import qualified Data.Vector as V

import Foreign.ForeignPtr ( ForeignPtr, withForeignPtr, castForeignPtr )
import Foreign.C.String ( withCString )
import Control.Monad.Trans.Except

--------------------------------------------------------------------------------

-- Rebuild the inline C++ binding whenever its implementation changes.
$(do
    addDependentFile "hs-src/Device/Camera/Hikvision/Camera.cpp"
    addDependentFile "hs-src/Device/Camera/Hikvision/Camera.hpp"
    addDependentFile "hs-src/Device/Camera/Hikvision/DeviceSelection.hpp"
    pure [])

C.context openCvCtx

C.include "Hikvision/Camera.cpp"
C.include "hikvision.hpp"

C.using "namespace cv"
C.using "namespace std"

newtype CameraHv = CameraHv {unCameraMv :: ForeignPtr C'Ptr_CameraHv}

type instance C CameraHv = C'Ptr_CameraHv

instance WithPtr CameraHv where
  withPtr = withForeignPtr . unCameraMv

mkFinalizer DeletePtr "deleteCameraHv" "Ptr_CameraHv" ''C'Ptr_CameraHv

instance FromPtr CameraHv where
  fromPtr = objFromPtr CameraHv deleteCameraHv

newEmptyCamPtr :: IO CameraHv
newEmptyCamPtr = fromPtr [CU.exp|Ptr_CameraHv * {new cv::Ptr<CameraH>()}|]

hv_init :: String -> ExceptT CvException IO CameraHv
hv_init camid = ExceptT $ withCString camid $ \camidPtr -> do
  mycam <- newEmptyCamPtr
  withPtr mycam $ \myCamPtr -> do
    handleCvException (pure $ mycam) $
      [cvExcept|
        cv::Ptr<CameraH> camPtr = cv::makePtr<CameraH>($(char* camidPtr));
        camPtr->start_video();
        *$(Ptr_CameraHv * myCamPtr) = camPtr;
      |]

hv_close :: CameraHv -> ExceptT CvException IO ()
hv_close cam = ExceptT $ do
  withPtr cam $ \camPtr ->
    handleCvException (pure ()) $
      [cvExcept|
         (**$(Ptr_CameraHv * camPtr)).closeCamera();
      |]


hv_readFrame :: CameraHv -> ExceptT CvException IO (Mat ('S ['D, 'D]) channels depth)
hv_readFrame cam = ExceptT $ do
  matOut <- newEmptyMat
  withPtr cam $ \camPtr ->
    withPtr matOut $ \matOutPtr ->
      handleCvException (pure $ unsafeCoerceMat matOut) $
        [cvExcept|
         *$(Mat * matOutPtr) = (**$(Ptr_CameraHv * camPtr)).readFrameMat();
        |]


hv_setProperties :: CameraHv -> String -> Double -> ExceptT CvException IO ()
hv_setProperties cam name value = ExceptT $ do
  withCString name $ \namePtr ->
   withPtr cam $ \camPtr ->
    handleCvException (pure ()) $
      [cvExcept|
         (**$(Ptr_CameraHv * camPtr)).setProperties($(char* namePtr), $(double c'value));
      |]
  where
    c'value = realToFrac value
