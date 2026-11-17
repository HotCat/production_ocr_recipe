
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

module Device.Projector.ChiMei (Projector, mkProjector, projectorCmd, setFringePattern, emitFringePattern, emitGammaPattern) where

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

C.context openCvCtx

C.include "unistd.h"
C.include "cvtools.h"
C.include "opencv2/opencv.hpp"
C.include "opencv2/imgproc/types_c.h"
C.include "ProjectorOpenGL.h"
C.include "OpenGLContext.h"
C.include "Projector.h"
C.include "CodecCalibration.h"
C.include "CalibrationData.h"
C.include "CodecFactory.h"

C.include "LC4500API/dlpc350_api.h"
C.include "LC4500API/dlpc350_usb.h"
C.include "thread"
C.include "chrono"
C.include "numeric"

C.using "namespace cv"
C.using "namespace std"

C.verbatim [r|
typedef cv::Ptr<ProjectorOpenGL> Ptr_Projector;

void showError(std::string err) {
    std::cerr << "get error: " << err << std::endl;
}
|]


newtype Projector = Projector {unProjector :: ForeignPtr C'Ptr_Projector}

type instance C Projector = C'Ptr_Projector

instance WithPtr Projector where
  withPtr = withForeignPtr . unProjector

mkFinalizer DeletePtr "deleteProjector" "Ptr_Projector" ''C'Ptr_Projector

instance FromPtr Projector where
  fromPtr = objFromPtr Projector deleteProjector


newProjector :: IO Projector
newProjector = fromPtr [CU.exp|Ptr_Projector * {new cv::Ptr<ProjectorOpenGL>()}|]



-- mkProjector :: IO Projector
-- mkProjector = fromPtr [C.block| Ptr_Projector * {
--                  cv::Ptr<ProjectorOpenGL> prjPtr = cv::makePtr<ProjectorOpenGL>(1);
--                  return new cv::Ptr<ProjectorOpenGL>(prjPtr);
--               }|]



mkProjector :: (MonadIO m, MonadError CvException m) => Int -> m Projector
mkProjector iscreen = wrapException $ liftIO $ do
  let c'iscreen = fromIntegral iscreen
  myprj <- newProjector
  withPtr myprj $ \myPrjPtr -> do
    handleCvException (pure $ myprj) $
      [cvExcept|
        cv::Ptr<ProjectorOpenGL> prjPtr = cv::makePtr<ProjectorOpenGL>($(int c'iscreen));
        *$(Ptr_Projector * myPrjPtr) = prjPtr;
      |]



projectorCmd :: (MonadIO m, MonadError CvException m) => Projector -> String -> m String
projectorCmd prj cmd = wrapException $ liftIO $ do
  withCString cmd $ \c'cmd -> do
    c'str <- mallocArray 100
    withPtr prj $ \prjPtr -> do
      handleCvException (pure $ unsafePerformIO $ (peekCAString c'str)) $
        [cvExcept|
          std::strcpy($(char * c'str), "projectorCmd");

          if(std::strcmp($(char * c'cmd), "turnon") == 0) {
            (**$(Ptr_Projector * prjPtr)).displayWhite();
          } else if(std::strcmp($(char * c'cmd), "turnoff") == 0) {
            (**$(Ptr_Projector * prjPtr)).displayBlack();
          } else if(std::strcmp($(char * c'cmd), "siemens") == 0) {
            (**$(Ptr_Projector * prjPtr)).setSiemens();
          } else if(std::strcmp($(char * c'cmd), "initusb") == 0) {
            DLPC350_USB_Init();
            if(DLPC350_USB_Open() == 0) {
              std::strcpy($(char * c'str), "ok");
            } else {
              std::strcpy($(char * c'str), "ng");
            }
          } else if(std::strcmp($(char * c'cmd), "powermode") == 0) {
            bool isStandby;
            DLPC350_GetPowerMode(&isStandby);
            if(isStandby) {
              std::strcpy($(char * c'str), "standby");
            } else {
              std::strcpy($(char * c'str), "normal");
            }
          } else if(std::strcmp($(char * c'cmd), "displaymode") == 0) {
            bool mode;
            DLPC350_GetMode(&mode);
            if(mode == true) {
              std::strcpy($(char * c'str), "pattern");
            } else {
              std::strcpy($(char * c'str), "video");
            }
          } else if(std::strcmp($(char * c'cmd), "wakeup") == 0) {
            DLPC350_SetPowerMode(0);
            std::strcpy($(char * c'str), "wakeup");
          } else if(std::strcmp($(char * c'cmd), "getpatterndisplay") == 0) {

            bool mode = true;
            DLPC350_GetMode(&mode);
            std::cout << "ProjectorLC4500: $$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$: " <<  mode << std::endl;
            if(mode == true) {
              unsigned int patMode = 100;
              DLPC350_GetPatternDisplay(&patMode);
              std::cout << "ProjectorLC4500: +++++++++++++++++++++++++++++++" << patMode << std::endl;

              if(patMode != 0) {
                int j = 0;

                DLPC350_PatternDisplay(0);
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                while(true) {
                  DLPC350_GetPatternDisplay(&patMode);
                  if (patMode == 0)
                    break;
                  else
                    DLPC350_PatternDisplay(0);
                  std::this_thread::sleep_for(std::chrono::milliseconds(200));
                  if (j++ > 5)
                    break;
                }
                std::strcpy($(char * c'str), "pattern cancelled");
              } else {
                std::strcpy($(char * c'str), "already cancelled");
              }
            } else {
              std::strcpy($(char * c'str), "already in video");
            }
            
          } else if(std::strcmp($(char * c'cmd), "add") == 0) {
            DLPC350_USB_Open();
            std::strcpy($(char * c'str), "add");
          } else if(std::strcmp($(char * c'cmd), "remove") == 0) {
            // DLPC350_USB_Close();
            std::strcpy($(char * c'str), "remove");
          } else if(std::strcmp($(char * c'cmd), "reset") == 0) {
            DLPC350_SoftwareReset();
            std::strcpy($(char * c'str), "reset");
          } else if(std::strcmp($(char * c'cmd), "gopattern") == 0) {
            DLPC350_SetMode(true);
            std::strcpy($(char * c'str), "gopattern");
          } else if(std::strcmp($(char * c'cmd), "cancelpat") == 0) {
            unsigned int patMode;
            DLPC350_GetPatternDisplay(&patMode);
            if(patMode == 0) {
              std::strcpy($(char * c'str), "cancelled");
            } else {
              DLPC350_PatternDisplay(0);
              std::strcpy($(char * c'str), "pending");
            }
          } else if(std::strcmp($(char * c'cmd), "play") == 0) {
            DLPC350_PatternDisplay(2);
            std::strcpy($(char * c'str), "play");
          } else if(std::strcmp($(char * c'cmd), "initPatlut") == 0) {
            bool SeqCtrl = true;
            bool LEDRed = true;
            bool LEDGreen = true;
            bool LEDBlue = true;

            DLPC350_SetLedEnables(SeqCtrl, LEDRed, LEDGreen, LEDBlue);

            bool inverted;
            if(DLPC350_GetLEDPWMInvert(&inverted) == 0) {
              std::cout << "ProjectorLC4500: pwm inverted: " << inverted << std::endl;
            }

            DLPC350_SetLEDPWMInvert(inverted);

            unsigned char RedCurrent = 104;
            unsigned char GreenCurrent = 135;
            unsigned char BlueCurrent = 130;
            DLPC350_SetLedCurrents(255 - RedCurrent, 255 - GreenCurrent, 255 - BlueCurrent);

            int i = 0;
            unsigned int patMode = 0;            

            // Stop the display
            DLPC350_PatternDisplay(0);

            while(true) {
              DLPC350_GetPatternDisplay(&patMode);

              if(patMode == 0)
                break;
              else
                DLPC350_PatternDisplay(0);
              std::this_thread::sleep_for(std::chrono::milliseconds(100));
              if(i++ > 5)
                break;
            }

            // Set pattern mode
            bool patternMode = true;
            DLPC350_SetMode(patternMode);

            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            bool mode;
            while(true) {
              DLPC350_GetMode(&mode);

              if(mode)
                break;

              std::this_thread::sleep_for(std::chrono::milliseconds(100));
              if(i++ > 5)
                break;
            }

            DLPC350_ClearPatLut();

            const int triggerTypeInternal = 0;
            const int bitPlanesIdx = 0;
            const int bitDepth = 8;
            const int ledWhite = 7;
            const bool invertPat = false;
            const bool insertBlack = true;
            const bool bufferSwap = true;
            const bool trigOutPrev = false;

            const int numPatterns = 6;
            const int patternNum = -1;

            // For 6 patterns arranged in groups of 3 (one group per splash image)
            // and the order within each group is G, R, B.
            for (int i = 0; i < numPatterns; ++i) {
              // Here, we assume that:
              //  - bit plane index 0 corresponds to Green,
              //  - 1 corresponds to Red, and
              //  - 2 corresponds to Blue.
              // This order may be inherent in the hardware's GRB ordering.
              const int bitPlanesIdx = i % 3;
              // Buffer swap is done at the start of each group (every 3 patterns)
              const bool bufferSwap = (i % 3 == 0);
              DLPC350_AddToPatLut(triggerTypeInternal, bitPlanesIdx, bitDepth, ledWhite, invertPat, insertBlack, bufferSwap, trigOutPrev);
            }

            bool fromHDMI = false;
            DLPC350_SetPatternDisplayMode(fromHDMI);

            // There are 6 patterns, and each splash image holds 3 patterns, so we need 4 splash images.
            const int numSplashImages = std::ceil(numPatterns / 3.0);
            const bool repeat = false; // For single-shot display
            const int numPatsForTrigOut2 = numPatterns;
            DLPC350_SetPatternConfig(numPatterns, repeat, numPatsForTrigOut2, numSplashImages);

            const double exposurePeriod = 8333.3;
            // Use the exposurePeriod provided; adjust as needed.
            DLPC350_SetExposure_FramePeriod(exposurePeriod, 20000);

            const int triggerModeInternal = 1;
            DLPC350_SetPatternTriggerMode(triggerModeInternal);

            // Send the Pattern LUT and validate
            DLPC350_SendPatLut();

            // Instead of starting at 0, we want our splash images to come from flash indices 3, 4, 5, and 6.
            std::vector<unsigned char> splashLut(numSplashImages);
            splashLut[0] = 8;
            splashLut[1] = 7;

            DLPC350_SendImageLut(splashLut.data(), numPatterns);

            DLPC350_StartPatLutValidate();

            bool ready = false;
            unsigned int status;
            i = 0;
            do {
              if(DLPC350_CheckPatLutValidate(&ready, &status) < 0) {
	      showError("Error validating LUT data");
	      return 0;
            }

            if(ready) {
	      break;
            }
            else {
	      std::this_thread::sleep_for(std::chrono::milliseconds(1000));
            }

            if(i++ > 5)
	      break;

            } while(1);

            std::strcpy($(char * c'str), "initPatlut");
         
          } else if(std::strcmp($(char * c'cmd), "initCalibPat") == 0) {
            std::vector<unsigned char> splashLut(2);
            splashLut[0] = 4;
            splashLut[1] = 3;

            DLPC350_SendImageLut(splashLut.data(), 6);
            DLPC350_StartPatLutValidate();
      
            bool ready = false;
            unsigned int status;
            int i = 0;
            do {
              DLPC350_CheckPatLutValidate(&ready, &status);
            
              if(ready) {
                break;
              }
              else {
                std::this_thread::sleep_for(std::chrono::milliseconds(1000));
              }
            
              if(i++ > 5)
                break;
            } while(1);

            std::strcpy($(char * c'str), "initCalibPat");

          } else if(std::strcmp($(char * c'cmd), "standby") == 0) {
            DLPC350_SetPowerMode(1);
            std::this_thread::sleep_for(std::chrono::milliseconds(2000));
          } else {
            std::cout << "Received unknown command: "<< $(char * c'cmd) <<std::endl;
          }

        |]


setFringePattern :: (MonadIO m, MonadError CvException m) => Projector -> String -> m String
setFringePattern prj what = wrapException $ liftIO $ do
  withCString what $ \c'what -> do
    c'str <- mallocArray 100
    withPtr prj $ \prjPtr -> do
      handleCvException (pure $ unsafePerformIO $ (peekCAString c'str)) $
        [cvExcept|
          std::strcpy($(char * c'str), "setFringePattern");
          std::vector<const unsigned char*> remappedPatterns;
          if(std::strcmp($(char * c'what), "intact") == 0) {
            unsigned int screenResX = 1000, screenResY = 1000;
            (**$(Ptr_Projector * prjPtr)).getScreenRes(&screenResX, &screenResY);
            std::unique_ptr<EncoderCalibration> encoder;
            encoder.reset(new EncoderCalibration(screenResX, screenResY, CodecDirBoth));

            std::vector<cv::Mat> patterns;
            // Upload patterns to projector/GPU
            patterns.resize(encoder->getNPatterns());
            std::vector<const uchar *> patternPtrs(encoder->getNPatterns());
            for (unsigned int i = 0; i < encoder->getNPatterns(); i++) {
              patterns[i] = encoder->getEncodingPattern(i);
    
              // general repmat
              patterns[i] = cv::repeat(patterns[i], screenResY / patterns[i].rows + 1,screenResX / patterns[i].cols + 1);
              patterns[i] = patterns[i](cv::Range(0, screenResY), cv::Range(0, screenResX));
              patternPtrs[i] = patterns[i].data;
            }

            remappedPatterns = (**$(Ptr_Projector * prjPtr)).remapPatterns(patternPtrs, patterns[0].cols, patterns[0].rows);
            (**$(Ptr_Projector * prjPtr)).setPatterns(remappedPatterns, patterns[0].cols/2, patterns[0].rows);
          }
          else if(std::strcmp($(char * c'what), "undistort") == 0) {
            unsigned int screenResX = 1000, screenResY = 1000;
            (**$(Ptr_Projector * prjPtr)).getScreenRes(&screenResX, &screenResY);

            CalibrationData calibration;
            calibration.load("/home/hotcat/Downloads/new3dvision/controller/1/calibration.xml");

            cv::Mat map1, map2;
            cv::Size mapSize = cv::Size(screenResX, screenResY);
            cvtools::initDistortMap(calibration.Kp, calibration.kp, mapSize, map1, map2);

            const std::string codecName = "PhaseShift2x3";
            std::unique_ptr<Encoder> encoder;
            encoder = EncoderFactory::NewEncoder(Codecs.at(codecName), screenResX, screenResY, CodecDirHorizontal);

            std::vector<cv::Mat> patterns(encoder->getNPatterns());
            std::vector<const uchar *> patternPtrs(encoder->getNPatterns());

            for (unsigned int i = 0; i < encoder.get()->getNPatterns(); ++i) {
              patterns[i] = encoder.get()->getEncodingPattern(i);

              // general repmat
              patterns[i] = cv::repeat(patterns[i], screenResY / patterns[i].rows + 1,screenResX / patterns[i].cols + 1);
              patterns[i] = patterns[i](cv::Range(0, screenResY), cv::Range(0, screenResX));

              cv::remap(patterns[i], patterns[i], map1, map2, cv::INTER_CUBIC);

              patternPtrs[i] = patterns[i].data;
            }

            remappedPatterns = (**$(Ptr_Projector * prjPtr)).remapPatterns(patternPtrs, patterns[0].cols, patterns[0].rows);
            (**$(Ptr_Projector * prjPtr)).setPatterns(remappedPatterns, patterns[0].cols/2, patterns[0].rows);
          }
          else {
            std::cout << "Received unknown command: "<< $(char * c'what) <<std::endl;
          }
        |]


emitFringePattern :: (MonadIO m, MonadError CvException m) => Projector -> Int -> m String
emitFringePattern prj seq = wrapException $ liftIO $ do
  let c'seq = fromIntegral seq
  c'str <- mallocArray 100
  withPtr prj $ \prjPtr -> do
    handleCvException (pure $ unsafePerformIO $ (peekCAString c'str)) $
      [cvExcept|
        std::strcpy($(char * c'str), "emitFringePattern");
        (**$(Ptr_Projector * prjPtr)).displayPattern($(int c'seq));
      |]


emitGammaPattern :: (MonadIO m, MonadError CvException m) => Projector -> Int -> m String
emitGammaPattern prj seq = wrapException $ liftIO $ do
  let c'seq = fromIntegral seq
  c'str <- mallocArray 100
  withPtr prj $ \prjPtr -> do
     handleCvException (pure $ unsafePerformIO $ (peekCAString c'str)) $
       [cvExcept|
         std::strcpy($(char * c'str), "emitGammaPattern");
         Mat tex(cvSize(1280, 960), CV_8UC3, Scalar($(int c'seq), $(int c'seq), $(int c'seq)));
         (**$(Ptr_Projector * prjPtr)).displayTexture(tex.data, tex.cols, tex.rows);
       |]


dispWhite :: (MonadIO m, MonadError CvException m) => Projector -> m ()
dispWhite prj = wrapException $ liftIO $
  withPtr prj $ \prjPtr ->
    handleCvException (pure ()) $
    [cvExcept|
        (**$(Ptr_Projector * prjPtr)).displayWhite();
    |]


projector :: IO ()
projector = do
    [CU.block| void {
      ProjectorOpenGL *pp = new ProjectorOpenGL(1);

      // Get screeninfo for OpenGL projector
      std::vector<ScreenInfo> screenInfo;
      screenInfo = OpenGLContext::GetScreenInfo();

      for (unsigned int i=0; i<screenInfo.size(); i++) {
          printf("Screen %d: width %d, height %d\n", i, screenInfo[i].resX,
          screenInfo[i].resY);
      }

      pp->displayBlack();
      // pp->displayWhite();

      return;

    }|]


projector2 :: IO ()
projector2 = do
    [CU.block| void {
      ProjectorOpenGL *pp = new ProjectorOpenGL(1);

      // Get screeninfo for OpenGL projector
      std::vector<ScreenInfo> screenInfo;
      screenInfo = OpenGLContext::GetScreenInfo();

      for (unsigned int i=0; i<screenInfo.size(); i++) {
          printf("Screen %d: width %d, height %d\n", i, screenInfo[i].resX,
          screenInfo[i].resY);
      }

      // pp->displayWhite();
      unsigned int screenResX = 1000, screenResY = 1000;
      pp->getScreenRes(&screenResX, &screenResY);
      std::cout << "screenResX: " << screenResX << std::endl;
      std::cout << "screenResY: " << screenResY << std::endl;

      std::unique_ptr<EncoderCalibration> encoder;
      encoder.reset(new EncoderCalibration(screenResX, screenResY, CodecDirBoth));

      std::vector<cv::Mat> patterns;
      // Upload patterns to projector/GPU
      patterns.resize(encoder->getNPatterns());
      std::vector<const uchar *> patternPtrs(encoder->getNPatterns());

      for (unsigned int i = 0; i < encoder->getNPatterns(); i++) {
        patterns[i] = encoder->getEncodingPattern(i);
        
        // general repmat
        patterns[i] = cv::repeat(patterns[i], screenResY / patterns[i].rows + 1,screenResX / patterns[i].cols + 1);
        patterns[i] = patterns[i](cv::Range(0, screenResY), cv::Range(0, screenResX));
        patternPtrs[i] = patterns[i].data;
      }

      // pp->setPatterns(patternPtrs, patterns[0].cols, patterns[0].rows);
      pp->remapPatterns(patternPtrs, patterns[0].cols, patterns[0].rows);

      for (unsigned int i = 0; i < encoder->getNPatterns(); i++) {
      // for (unsigned int i = 0; i < 6; i++) {
        pp->displayPattern(i);
        usleep(50000);
      }
      
      std::cout << "displayPattern done!" << std::endl;
      delete(pp);

      return;
    }|]


