
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

module Device.Vision.Algorithms (releaseMat, buildAffine, findAngle, findTranslation, findScale, translation, rotateAffine) where

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

import Control.Monad.IO.Class ( MonadIO, liftIO )
import Control.Monad.Error.Class ( MonadError )

--------------------------------------------------------------------------------

C.context openCvCtx

C.include "<stdlib.h>"

C.include "opencv2/opencv.hpp"
C.include "Algorithms/affine.cpp"

C.using "namespace cv"
C.using "namespace std"
C.using "namespace vision"


releaseMat :: (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO ()
releaseMat img = do
  withPtr img $ \imgPtr -> do
    [CU.block| void {
      sinkMat(*$(Mat * imgPtr));
    }|]


-- buildAffine :: String -> String -> Mat (ShapeT [2, 3]) ('S 1) ('S Double)
-- buildAffine pixels worlds = unsafeCoerceMat $ unsafePerformIO $ do
--   withCString pixels $ \c'pixels -> do
--     withCString worlds $ \c'worlds -> do
--       fromPtr
--         [CU.block| Mat * {
--           std::string a = $(char* c'pixels);
--           std::string b = $(char* c'worlds);
--           return new cv::Mat
--           (  cv::estimateAffine2D(string2Point2d(a), string2Point2d(b))
--           );
--         }|]


findAngle :: (Mat (ShapeT [2, 3]) ('S 1) ('S Double)) -> Double
findAngle matrix = realToFrac $ unsafePerformIO $ withPtr matrix $ \matrixPtr ->
  [CU.block| double {
      double angleRadians = std::atan2((*$(Mat * matrixPtr)).at<double>(1,0), (*$(Mat * matrixPtr)).at<double>(1,1));
      double angleDegrees = angleRadians * 180.0 /CV_PI;
      return angleDegrees;
  }|]


findTranslation :: (Mat (ShapeT [2, 3]) ('S 1) ('S Double)) -> (Double, Double)
findTranslation matrix = unsafePerformIO $ do
  withPtr matrix $ \matrixPtr -> do
    [a,b] <- allocaArray 2 \worldPtr -> do
               [CU.block| void {
                 $(double* worldPtr)[0] = (*$(Mat * matrixPtr)).at<double>(0,2);
                 $(double* worldPtr)[1] = (*$(Mat * matrixPtr)).at<double>(1,2);
               }|]
               a <- peekArray 2 worldPtr
               return $ (map realToFrac a)
    return $ (a, b)


findScale :: (Mat (ShapeT [2, 3]) ('S 1) ('S Double)) -> (Double, Double)
findScale matrix = unsafePerformIO $ do
  withPtr matrix $ \matrixPtr -> do
    [a,b] <- allocaArray 2 \worldPtr -> do
               [CU.block| void {
                 double a = (*$(Mat * matrixPtr)).at<double>(0,0);
                 double b = (*$(Mat * matrixPtr)).at<double>(0,1);
                 double d = (*$(Mat * matrixPtr)).at<double>(1,0);
                 double e = (*$(Mat * matrixPtr)).at<double>(1,1);

                 $(double* worldPtr)[0] = sqrt(a * a + b * b);
                 $(double* worldPtr)[1] = sqrt(d * d + e * e);
               }|]
               a <- peekArray 2 worldPtr
               return $ (map realToFrac a)
    return $ (a, b)


translation :: (Mat (ShapeT [2, 3]) ('S 1) ('S Double)) -> Double -> Double -> (Double, Double)
translation matrix x y = unsafePerformIO $ do
  let c'x = realToFrac x
      c'y = realToFrac y
  withPtr matrix $ \matrixPtr -> do
    [a,b] <- allocaArray 2 \worldPtr -> do
               [CU.block| void {
                 vector<Point2d> myPoint(1);
                 myPoint[0] = Point2d($(double c'x), $(double c'y));
                 vector<Point2d> transformedPoint(1);
                 cv::transform(myPoint, transformedPoint, *$(Mat * matrixPtr));

                 $(double* worldPtr)[0] = transformedPoint[0].x;
                 $(double* worldPtr)[1] = transformedPoint[0].y;
               }|]
               a <- peekArray 2 worldPtr
               return $ (map realToFrac a)
    return $ (a, b)

newEmptyAffine :: IO (Mat (ShapeT [2, 3]) ('S 1) ('S Double))
newEmptyAffine = unsafeCoerceMat <$> fromPtr [CU.exp|Mat * { new Mat() }|]


buildAffine :: (MonadIO m, MonadError CvException m) => String -> String -> m (Mat (ShapeT [2, 3]) ('S 1) ('S Double))
buildAffine pixels worlds = wrapException $ liftIO $ do
  matOut <- newEmptyAffine
  handleCvException (pure $ unsafeCoerceMat matOut) $
    withPtr matOut $ \matOutPtr ->
      withCString pixels $ \c'pixels -> do
        withCString worlds $ \c'worlds -> do
            [cvExcept|
              std::string a = $(char* c'pixels);
              std::string b = $(char* c'worlds);
              Mat affine = cv::estimateAffine2D(string2Point2d(a), string2Point2d(b));
              if(!affine.empty() && affine.rows == 2 && affine.cols == 3) {
                *$(Mat * matOutPtr) = affine;
              } else {
                CV_Assert(false);
              }
            |]


-- rotateAffine :: (Mat (ShapeT [2, 3]) ('S 1) ('S Double)) -> Double -> (Mat (ShapeT [2, 3]) ('S 1) ('S Double))
-- rotateAffine matrix angle = unsafePerformIO $ do
--   let c'angle = realToFrac angle
--   matOut <- newEmptyAffine
--   withPtr matOut $ \matOutPtr ->
--     withPtr matrix $ \matrixPtr -> do
--       [CU.block| void {
--         Mat rotationMat = cv::getRotationMatrix2D({0, 0}, $(double c'angle), 1.0);
--         std::cout << "rotationMat.rows: " <<  rotationMat.rows << '\n';
--         std::cout << "rotationMat.cols: " <<  rotationMat.cols << '\n';
--         std::cout << "matrixPtr.rows: " <<  (*$(Mat * matrixPtr)).rows << '\n';
--         std::cout << "matrixPtr.cols: " <<  (*$(Mat * matrixPtr)).cols << '\n';

--         // cv::gemm((*$(Mat * matrixPtr)), rotationMat, 1.0, cv::Mat(), 0.0, *$(Mat * matOutPtr));
--         // *$(Mat * matOutPtr) = rotationMat * (*$(Mat * matrixPtr));
--       }|]
--   return $ matOut



rotateAffine :: (Mat (ShapeT [2, 3]) ('S 1) ('S Double)) -> Double -> (Mat (ShapeT [2, 3]) ('S 1) ('S Double))
rotateAffine matrix angle = unsafePerformIO $ do
  let c'angle = realToFrac angle
  matOut <- newEmptyAffine
  withPtr matOut $ \matOutPtr ->
    withPtr matrix $ \matrixPtr -> do
      [CU.block| void {
        double angleRadians = $(double c'angle) * CV_PI / 180.0;
        double tx = (*$(Mat * matrixPtr)).at<double>(0,2);
        double ty = (*$(Mat * matrixPtr)).at<double>(1,2);

        double a = (*$(Mat * matrixPtr)).at<double>(0,0);
        double b = (*$(Mat * matrixPtr)).at<double>(0,1);
        double d = (*$(Mat * matrixPtr)).at<double>(1,0);
        double e = (*$(Mat * matrixPtr)).at<double>(1,1);

        double scalex = sqrt(a * a + b * b);
        double scaley = sqrt(d * d + e * e);

        Mat newAffine = (cv::Mat_<double>(2, 3) <<
                        scalex * std::cos(angleRadians), -scaley * std::sin(angleRadians), tx,
                        scalex * std::sin(angleRadians), scaley * std::cos(angleRadians), ty);

        *$(Mat * matOutPtr) = newAffine;

      }|]
  return $ matOut
