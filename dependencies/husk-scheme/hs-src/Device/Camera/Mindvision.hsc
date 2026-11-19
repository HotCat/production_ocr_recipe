
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

module Device.Camera.Mindvision (CameraMv, mv_init2, mv_close, mv_readFrame, mv_captureProfilo, mv_profiloCircle, mv_captureSequence, mv_setProperties) where

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

C.include "Mindvision/Camera.cpp"
C.include "mindvision.hpp"

C.using "namespace cv"
C.using "namespace std"

C.verbatim [r|
typedef cv::Ptr<Reconstruct> Ptr_Reconstruct;
|]

newtype CameraMv = CameraMv {unCameraMv :: ForeignPtr C'Ptr_CameraMv}

type instance C CameraMv = C'Ptr_CameraMv

instance WithPtr CameraMv where
  withPtr = withForeignPtr . unCameraMv

mkFinalizer DeletePtr "deleteCameraMv" "Ptr_CameraMv" ''C'Ptr_CameraMv

-- instance FromPtr CameraMv where
--   fromPtr = objFromPtr CameraMv $ \ptr ->
--     [CU.block| void {
--         cv::Ptr<CameraM> * mv_ptr_ptr = $(Ptr_CameraMv * ptr);
--         mv_ptr_ptr->release();
--         delete mv_ptr_ptr;
--     }|]


instance FromPtr CameraMv where
  fromPtr = objFromPtr CameraMv deleteCameraMv



mv_init :: String -> IO CameraMv
mv_init camid = withCString camid $ \camidPtr ->
  fromPtr [C.block| Ptr_CameraMv * {
       CameraM cam($(char* camidPtr));
       cam.setProperties("PIXLE",0.8);

       std::string camid($(char* camidPtr));
       if(camid == "MV-up") {
         cam.setProperties("SwitchResolution",9.0);
         cam.setProperties("SetNoiseFilter",1.0);
       }

       cam.start_video();
       cv::Ptr<CameraM> camPtr = cv::makePtr<CameraM>(cam);
       return new cv::Ptr<CameraM>(camPtr);
       }|]

newEmptyCamPtr :: IO CameraMv
newEmptyCamPtr = fromPtr [CU.exp|Ptr_CameraMv * {new cv::Ptr<CameraM>()}|]

mv_init2 :: (MonadIO m, MonadError CvException m) => String -> m CameraMv
mv_init2 camid = wrapException $ liftIO $ withCString camid $ \camidPtr -> do
  mycam <- newEmptyCamPtr
  withPtr mycam $ \myCamPtr -> do
    handleCvException (pure $ mycam) $
      [cvExcept|
        cv::Ptr<CameraM> camPtr = cv::makePtr<CameraM>($(char* camidPtr));
        camPtr->setProperties("PIXLE",0.8);

        std::string camid($(char* camidPtr));
        if(camid == "MV-up") {
          // camPtr->setProperties("SwitchResolution",9.0);
          // camPtr->setProperties("SetNoiseFilter",1.0);
        }

        if(camid == "MV-down") {
          // camPtr->setProperties("SwitchResolution",9.0);
          // camPtr->setProperties("SetNoiseFilter",1.0);
        }

        camPtr->start_video();
        *$(Ptr_CameraMv * myCamPtr) = camPtr;
      |]

mv_init3 :: String -> IO (Either CvException CameraMv)
mv_init3 camid = runExceptT $ mv_init2 camid


-- mv_readFrame :: CameraMv -> CvExceptT IO (Mat ('S ['D, 'D]) channels depth)
-- mv_readFrame cam = ExceptT $ do
--   matOut <- newEmptyMat
--   withPtr cam $ \camPtr ->
--     withPtr matOut $ \matOutPtr ->
--       handleCvException (pure $ unsafeCoerceMat matOut) $
--         [cvExcept|
--           Mat accumulated_frame;
--           Mat frame;

--           for (int i=0; i < 3; ++i) {
--             frame = (**$(Ptr_CameraMv * camPtr)).readFrameMat();
--             Mat gray_frame;
--             cvtColor(frame, gray_frame, COLOR_BGR2GRAY);

--             if(accumulated_frame.empty()) {
--               accumulated_frame = Mat::zeros(gray_frame.size(), CV_32F);
--             }
--             accumulate(gray_frame, accumulated_frame);
--           }
--           Mat average_frame, ultimate_frame;
--           convertScaleAbs(accumulated_frame / 3, average_frame);
--           //*$(Mat * matOutPtr) = (**$(Ptr_CameraMv * camPtr)).readFrameMat();
--           cvtColor(average_frame, ultimate_frame, COLOR_GRAY2BGR);
--           *$(Mat * matOutPtr) = ultimate_frame;
--         |]


mv_close :: (MonadIO m, MonadError CvException m) => CameraMv -> m ()
mv_close cam = wrapException $ liftIO $ do
  withPtr cam $ \camPtr ->
    handleCvException (pure ()) $
      [cvExcept|
         (**$(Ptr_CameraMv * camPtr)).closeCamera();
      |]


mv_readFrame :: (MonadIO m, MonadError CvException m) => CameraMv -> m (Mat ('S ['D, 'D]) channels depth)
mv_readFrame cam = wrapException $ liftIO $ do
  matOut <- newEmptyMat
  withPtr cam $ \camPtr ->
    withPtr matOut $ \matOutPtr ->
      handleCvException (pure $ unsafeCoerceMat matOut) $
        [cvExcept|
          *$(Mat * matOutPtr) = (**$(Ptr_CameraMv * camPtr)).readFrameMat();
        |]



-- mv_readFrameAsync :: (MonadIO m, MonadError CvException m) => CameraMv -> m (Mat ('S ['D, 'D]) channels depth)
-- mv_readFrameAsync cam = wrapException $ liftIO $ do
--   matOut <- newEmptyMat
--   withPtr cam $ \camPtr ->
--     withPtr matOut $ \matOutPtr ->
--       handleCvException (pure $ unsafeCoerceMat matOut) $
--         [cvExcept|
--           *$(Mat * matOutPtr) = (**$(Ptr_CameraMv * camPtr)).readFrameMatAsync();
--         |]


mv_captureSequence :: (MonadIO m, MonadError CvException m) => CameraMv -> Int -> m ()
mv_captureSequence cam dir = wrapException $ liftIO $ do
  let c'dir = fromIntegral dir
  withPtr cam $ \camPtr ->
    handleCvException (pure ()) $
      [cvExcept|
        (**$(Ptr_CameraMv * camPtr)).captureSequence($(int c'dir));
      |]


mv_captureProfilo :: (MonadIO m, MonadError CvException m) => CameraMv -> Reconstruct -> Int -> m Int
mv_captureProfilo cam recon thresh = wrapException $ liftIO $ do
  let ret = 0
      c'thresh = fromIntegral thresh

  withPtr cam $ \camPtr -> do
    with (fromIntegral ret) \vPtr -> do
      withPtr recon $ \reconPtr -> do
        handleCvException
          (fromIntegral <$> peek vPtr)
          [cvExcept|
              (**$(Ptr_CameraMv * camPtr)).captureProfilo((**$(Ptr_Reconstruct * reconPtr)), $(int c'thresh));
              *$(int* vPtr) = 0;
          |]


mv_profiloCircle :: (MonadIO m, MonadError CvException m) => CameraMv -> Reconstruct -> Int -> m Int
mv_profiloCircle cam recon thresh = wrapException $ liftIO $ do
  let ret = 0
      c'thresh = fromIntegral thresh

  withPtr cam $ \camPtr -> do
    with (fromIntegral ret) \vPtr -> do
      withPtr recon $ \reconPtr -> do
        handleCvException
          (fromIntegral <$> peek vPtr)
          [cvExcept|
              (**$(Ptr_CameraMv * camPtr)).profiloCircle((**$(Ptr_Reconstruct * reconPtr)), $(int c'thresh));
              *$(int* vPtr) = 0;
          |]


mv_setProperties :: (MonadIO m, MonadError CvException m) => CameraMv -> String -> Double -> m ()
mv_setProperties cam name value = wrapException $ liftIO $ do
  withCString name $ \namePtr ->
   withPtr cam $ \camPtr ->
    handleCvException (pure ()) $
      [cvExcept|
         (**$(Ptr_CameraMv * camPtr)).setProperties($(char* namePtr), $(double c'value));
      |]
  where
    c'value = realToFrac value


-- mv_emptyMat :: IO (Mat ('S ['D, 'D]) channels depth)
-- mv_emptyMat = do
--   matOut <- newEmptyMat
--   return $ unsafeCoerceMat matOut
