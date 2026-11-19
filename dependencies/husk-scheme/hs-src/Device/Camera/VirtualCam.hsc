{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

module Device.Camera.VirtualCam (CameraVi, vc_init, vc_close, vc_readFrame, vc_setProperties) where

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
import OpenCV.TypeLevel
import System.IO.Unsafe ( unsafePerformIO )
import OpenCV.Internal.C.FinalizerTH


import Control.Monad.IO.Class ( MonadIO, liftIO )
import Control.Monad.Error.Class ( MonadError )
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
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException, wrapException )
import OpenCV.TypeLevel
import qualified Data.Vector as V

import Foreign.ForeignPtr ( ForeignPtr, withForeignPtr, castForeignPtr )
import Foreign.C.String ( withCString )
import Control.Monad.Trans.Except
import Text.RawString.QQ

import Device.Pointcloud.Profilometry
import Foreign
import Foreign.C



--------------------------------------------------------------------------------

C.context openCvCtx

C.include "VirtualCam/Camera.cpp"
C.include "thread"


C.verbatim [r|
typedef cv::Ptr<CameraV> Ptr_CameraVi;
|]

C.using "namespace cv"
C.using "namespace std"


newtype CameraVi = CameraVi {unCameraVi :: ForeignPtr C'Ptr_CameraVi}

type instance C CameraVi = C'Ptr_CameraVi

instance WithPtr CameraVi where
  withPtr = withForeignPtr . unCameraVi

mkFinalizer DeletePtr "deleteCameraVi" "Ptr_CameraVi" ''C'Ptr_CameraVi


instance FromPtr CameraVi where
  fromPtr = objFromPtr CameraVi deleteCameraVi


newEmptyCamPtr :: IO CameraVi
newEmptyCamPtr = fromPtr [CU.exp|Ptr_CameraVi * {new cv::Ptr<CameraV>()}|]


vc_init :: (MonadIO m, MonadError CvException m) => String -> m CameraVi
vc_init camid = wrapException $ liftIO $ withCString camid $ \camidPtr -> do
  mycam <- newEmptyCamPtr
  withPtr mycam $ \myCamPtr -> do
    handleCvException (pure $ mycam) $
      [cvExcept|
        cv::Ptr<CameraV> camPtr = cv::makePtr<CameraV>($(char* camidPtr));
        *$(Ptr_CameraVi * myCamPtr) = camPtr;
      |]




vc_close :: (MonadIO m, MonadError CvException m) => CameraVi -> m ()
vc_close cam = wrapException $ liftIO $ do
  withPtr cam $ \camPtr ->
    handleCvException (pure ()) $
      [cvExcept|
         (**$(Ptr_CameraVi * camPtr)).closeCamera();
      |]



vc_readFrame :: (MonadIO m, MonadError CvException m) => CameraVi -> m (Mat ('S ['D, 'D]) channels depth)
vc_readFrame cam = wrapException $ liftIO $ do
  matOut <- newEmptyMat
  withPtr cam $ \camPtr ->
    withPtr matOut $ \matOutPtr ->
      handleCvException (pure $ unsafeCoerceMat matOut) $
        [cvExcept|
          *$(Mat * matOutPtr) = (**$(Ptr_CameraVi * camPtr)).readFrameMat();
          std::this_thread::sleep_for(std::chrono::milliseconds(15));
        |]


vc_setProperties :: (MonadIO m, MonadError CvException m) => CameraVi -> String -> Double -> m ()
vc_setProperties cam name value = wrapException $ liftIO $ do
  withCString name $ \namePtr ->
   withPtr cam $ \camPtr ->
    handleCvException (pure ()) $
      [cvExcept|
         (**$(Ptr_CameraVi * camPtr)).setProperties($(char* namePtr), $(double c'value));
      |]
  where
    c'value = realToFrac value
