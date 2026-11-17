
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Device.Pointcloud.Profilometry (Reconstruct, mkReconstruct, addFrame, setConfigIndex, setProfiloBlend, setCalibSequence, setLabelMorphology, setProductMorphology, getCalibSequence, setLabelResolution, getLabelExtent, setLabelExtent, setLabelAdjustOffset, setLabelDenoise, setProductDenoise, setProductResolution, setDistanceThreshold, setNozzleResolution, setNozzleThreshold, setTargetTranslation, setMotionHandle, getTargetTranslation, getWrapBoundingBox) where

import Data.Word
import Data.Char
import Foreign.C.Types
import Foreign.C.String
import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU
import qualified Language.C.Inline.Cpp as C
import qualified Data.ByteString as B

import qualified OpenCV
import OpenCV.Core.Types
import OpenCV.Internal
import OpenCV.Internal.C.Inline ( openCvCtx )
import OpenCV.Internal.C.Types
import OpenCV.Internal.Core.ArrayOps
import OpenCV.Internal.Core.Types ( withArrayPtr, Scalar )
import OpenCV.Internal.Core.Types.Mat
import OpenCV.Internal.C.FinalizerTH
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException, wrapException )
import OpenCV.TypeLevel

import Control.Monad
import Control.Exception
import Control.Monad.Error.Class ( MonadError )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Text as T

import Foreign.ForeignPtr ( ForeignPtr, withForeignPtr, castForeignPtr )
import Foreign.Marshal.Array
import Foreign.Marshal.Alloc
import System.IO.Unsafe ( unsafePerformIO )
import Text.RawString.QQ

import Graphics.GL
import Data.IORef
import System.Exit (exitFailure)
import Foreign.Ptr
import Foreign.Storable
import Data.IORef
import Data.Vector.Storable (Vector)

import Device.Motion.ZMotion
  
import Foreign
import Foreign.C

import Linear

C.context openCvCtx

C.include "reconstruct.h"

C.using "namespace cv"
C.using "namespace std"


C.verbatim [r|
typedef cv::Ptr<Reconstruct> Ptr_Reconstruct;
|]

newtype Reconstruct = Reconstruct {unReconstruct :: ForeignPtr C'Ptr_Reconstruct}

type instance C Reconstruct = C'Ptr_Reconstruct

instance WithPtr Reconstruct where
  withPtr = withForeignPtr . unReconstruct

mkFinalizer DeletePtr "deleteReconstruct" "Ptr_Reconstruct" ''C'Ptr_Reconstruct

instance FromPtr Reconstruct where
  fromPtr = objFromPtr Reconstruct deleteReconstruct



newReconstruct :: IO Reconstruct
newReconstruct = fromPtr [CU.exp|Ptr_Reconstruct * {new cv::Ptr<Reconstruct>()}|]


mkReconstruct :: (MonadIO m, MonadError CvException m) => m Reconstruct
mkReconstruct = wrapException $ liftIO $ do
  recon <- newReconstruct
  withPtr recon $ \reconPtr -> do
    handleCvException (pure $ recon) $
      [cvExcept|
        cv::Ptr<Reconstruct> reconPtr = cv::makePtr<Reconstruct>();
        *$(Ptr_Reconstruct * reconPtr) = reconPtr;
      |]


addFrame :: (MonadIO m, MonadError CvException m) => Reconstruct -> Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> Int -> m Int
addFrame recon img thresh = wrapException $ liftIO $ do
  let ret = 0
      c'thresh = fromIntegral thresh

  with (
    fromIntegral ret) \vPtr -> do
    withPtr img $ \imgPtr ->
      withPtr recon $ \reconPtr ->
        handleCvException
          (fromIntegral <$> peek vPtr)
          [cvExcept|
              *$(int* vPtr) = (**$(Ptr_Reconstruct * reconPtr)).addFrame((*$(Mat * imgPtr)), $(int c'thresh));
          |]


setConfigIndex :: (MonadIO m, MonadError CvException m) => Reconstruct -> Int -> m ()
setConfigIndex recon index = wrapException $ liftIO $ do
  let c'index = fromIntegral index
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setConfigIndex($(int c'index));
      |]

            
setProfiloBlend :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setProfiloBlend recon blend = wrapException $ liftIO $ do
  let c'blend = realToFrac blend
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setProfiloBlend($(double c'blend));
      |]


setCalibSequence :: (MonadIO m, MonadError CvException m) => Reconstruct -> Int -> m ()
setCalibSequence recon sequence = wrapException $ liftIO $ do
  let c'sequence = fromIntegral sequence
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setCalibSequence($(int c'sequence));
      |]


setLabelMorphology :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setLabelMorphology recon value = wrapException $ liftIO $ do
  let c'value = realToFrac value
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setLabelMorphology($(double c'value));
      |]


setProductMorphology :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setProductMorphology recon value = wrapException $ liftIO $ do
  let c'value = realToFrac value
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setProductMorphology($(double c'value));
      |]



setLabelResolution :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setLabelResolution recon value = wrapException $ liftIO $ do
  let c'value = realToFrac value
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setLabelResolution($(double c'value));
      |]


setLabelAdjustOffset :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> Float -> m ()
setLabelAdjustOffset recon dx dy = wrapException $ liftIO $ do
  let c'dx = realToFrac dx
      c'dy = realToFrac dy
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setLabelAdjustOffset($(double c'dx), $(double c'dy));
      |]


getLabelExtent :: (MonadIO m, MonadError CvException m) => Reconstruct -> m (V2 Float)
getLabelExtent recon = wrapException $ liftIO $ do
  allocaArray 2 \doublePtr -> do
    withPtr recon $ \reconPtr ->
      handleCvException
        (do
            [a,b] <- peekArray 2 doublePtr
            return (V2 (realToFrac a) (realToFrac b)))
        [cvExcept|
            Eigen::Vector2d extent;
            extent = (**$(Ptr_Reconstruct * reconPtr)).getLabelExtent();
            $(double* doublePtr)[0] = extent(0);
            $(double* doublePtr)[1] = extent(1);
        |]


setLabelExtent :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> Float -> m ()
setLabelExtent recon width height = wrapException $ liftIO $ do
  let c'width = realToFrac width
      c'height = realToFrac height
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setLabelExtent($(double c'width), $(double c'height));
      |]


setLabelDenoise :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> Float -> m ()
setLabelDenoise recon neighbors ratio = wrapException $ liftIO $ do
  let c'neighbors = realToFrac neighbors
      c'ratio = realToFrac ratio
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setLabelDenoise($(double c'neighbors), $(double c'ratio));
      |]


setProductDenoise :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> Float -> m ()
setProductDenoise recon neighbors ratio = wrapException $ liftIO $ do
  let c'neighbors = realToFrac neighbors
      c'ratio = realToFrac ratio
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setProductDenoise($(double c'neighbors), $(double c'ratio));
      |]


setProductResolution :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setProductResolution recon value = wrapException $ liftIO $ do
  let c'value = realToFrac value
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setProductResolution($(double c'value));
      |]


setDistanceThreshold :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setDistanceThreshold recon value = wrapException $ liftIO $ do
  let c'value = realToFrac value
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setDistanceThreshold($(double c'value));
      |]


setNozzleResolution :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setNozzleResolution recon value = wrapException $ liftIO $ do
  let c'value = realToFrac value
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setNozzleResolution($(double c'value));
      |]


setNozzleThreshold :: (MonadIO m, MonadError CvException m) => Reconstruct -> Float -> m ()
setNozzleThreshold recon value = wrapException $ liftIO $ do
  let c'value = realToFrac value
  withPtr recon $ \reconPtr ->
    handleCvException
      (pure ())
      [cvExcept|
          (**$(Ptr_Reconstruct * reconPtr)).setNozzleThreshold($(double c'value));
      |]



identityMatrix = V4 (V4 1 0 0 0) (V4 0 1 0 0) (V4 0 0 1 0) (V4 0 0 0 1)

-- Convert M44 to Ptr Float
withM44 :: M44 Float -> (Ptr CFloat -> IO a) -> IO a
withM44 (V4 (V4 a00 a01 a02 a03)
             (V4 a10 a11 a12 a13)
             (V4 a20 a21 a22 a23)
             (V4 a30 a31 a32 a33)) f =
  let arr = [ realToFrac a00, realToFrac a01, realToFrac a02, realToFrac a03
            , realToFrac a10, realToFrac a11, realToFrac a12, realToFrac a13
            , realToFrac a20, realToFrac a21, realToFrac a22, realToFrac a23
            , realToFrac a30, realToFrac a31, realToFrac a32, realToFrac a33]
  in withArray arr f


getWrapBoundingBox :: (MonadIO m, MonadError CvException m) => Reconstruct -> Int -> m (M44 Float)
getWrapBoundingBox recon index = wrapException $ liftIO $ do
  let curModel = identityMatrix
      c'index = fromIntegral index
  withM44 curModel $ \curModelPtr -> do
    withPtr recon $ \reconPtr ->
      handleCvException
        (do
            newModel <- peekArray 16 curModelPtr
            let [d11, d12, d13, d14, d21, d22, d23, d24, d31, d32, d33, d34, d41, d42, d43, d44] = map realToFrac newModel
            return (V4 (V4 d11 d12 d13 d14)
                    (V4 d21 d22 d23 d24)
                    (V4 d31 d32 d33 d34)
                    (V4 d41 d42 d43 d44))
            )
        [cvExcept|
            Eigen::Matrix4f gizmo;
            gizmo = (**$(Ptr_Reconstruct * reconPtr)).getWrapModel($(int c'index));
            memcpy($(float* curModelPtr), gizmo.data(), 16*sizeof(float));
        |]


getCalibSequence :: (MonadIO m, MonadError CvException m) => Reconstruct -> m Int
getCalibSequence recon = wrapException $ liftIO $ do
  alloca $ \(seqPtr :: (Ptr CInt)) ->
    withPtr recon $ \reconPtr ->
      handleCvException
        (fromIntegral <$> (peek seqPtr))
        [cvExcept|
            *$(int* seqPtr) = (**$(Ptr_Reconstruct * reconPtr)).getCalibSequence();
        |]


setTargetTranslation :: (MonadIO m, MonadError CvException m) => Reconstruct -> V3 Double -> m ()
setTargetTranslation recon (V3 x y z) = wrapException $ liftIO $ do
  withArray [ realToFrac x, realToFrac y, realToFrac z] \floatPtr -> do
    withPtr recon $ \reconPtr ->
      handleCvException
        (pure ())
        [cvExcept|
            Eigen::Vector3d translation($(float* floatPtr)[0], $(float* floatPtr)[1], $(float* floatPtr)[2]);
            (**$(Ptr_Reconstruct * reconPtr)).setTargetTranslation(translation);
        |]



setMotionHandle :: (MonadIO m, MonadError CvException m) => Reconstruct -> ModbusZv -> m ()
setMotionHandle recon bus = wrapException $ liftIO $ do
  withPtr bus $ \busPtr ->
    withPtr recon $ \reconPtr ->
      handleCvException
        (pure ())
        [cvExcept|
            (**$(Ptr_Reconstruct * reconPtr)).setMotionHandle((**$(Ptr_ModbusZv * busPtr)));
        |]



getTargetTranslation :: (MonadIO m, MonadError CvException m) => Reconstruct -> m (V3 Double)
getTargetTranslation recon = wrapException $ liftIO $ do
  allocaArray 3 \doublePtr -> do
    withPtr recon $ \reconPtr ->
      handleCvException
        (do
            [a,b,c] <- peekArray 3 doublePtr
            return (V3 (realToFrac a) (realToFrac b) (realToFrac c)))
        [cvExcept|
            Eigen::Vector3d translation;
            translation = (**$(Ptr_Reconstruct * reconPtr)).getTargetTranslation();
            $(double* doublePtr)[0] = translation(0);
            $(double* doublePtr)[1] = translation(1);
            $(double* doublePtr)[2] = translation(2);
        |]
          
