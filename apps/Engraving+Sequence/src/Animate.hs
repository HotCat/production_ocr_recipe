{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE BangPatterns #-}

module Animate (mkInitAndGetTimeInput
                ) where

import RuntimePaths

import           Control.Monad (when)
import           Graphics.UI.GLFW
import           Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map

import           DearImGui
import           FRP.Yampa
import           FRP.Yampa.Event
import           Diagnostics (intErr)
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TChan

import           Data.Vector.Storable   (Vector)
import qualified Data.Vector.Storable   as V
import           Linear

import           Object
import           Data.IORef
import           System.IO
import           Text.Printf
import           Language.Scheme.Types
import qualified Language.Scheme.Core as LSC

import           Data.Word
import           Graphics.GL
import           Foreign.Marshal.Alloc
import           Foreign.Ptr
import           Foreign.Storable
import           Control.Monad (when, void, unless)
import           System.Exit
import           System.IO.Unsafe (unsafePerformIO)
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


-- StateVar
import Data.StateVar
  ( HasGetter(get), HasSetter, ($=!) )

animate :: IO ()
animate = do
  return ()


makeTexture :: IO GLuint
makeTexture = do
  alloca $ \texturePtr -> do
    glGenTextures 1 texturePtr
    dumpError "glGenTextures 1 texturePtr"
    textureId <- peek texturePtr
    glBindTexture GL_TEXTURE_2D textureId
    dumpError "glBindTexture GL_TEXTURE_2D =<< peek texturePtr"
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_S GL_REPEAT
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_T GL_REPEAT
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_LINEAR
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_LINEAR
    return textureId

mkInitAndGetTimeInput env newInput ctrlMaps = do

    tpRef     <- newIORef errInitNotCalled
    wepRef    <- newIORef errInitNotCalled
    weBufRef  <- newIORef Nothing
    closedRef <- newIORef False

    refSlider1 <- newIORef (0.0, 0.0, 0.314)
    refSlider2 <- newIORef 1.0
    refSlider3 <- newIORef 42.0
    refSlider4 <- newIORef 132.0
    refSlider5 <- newIORef 4.0
    refSlider6 <- newIORef 21.0
    refSlider7 <- newIORef 20000.0
    refSlider8 <- newIORef 100.0
    refSlider9 <- newIORef 200.0
    refSlider10 <- newIORef 1.0
    refSlider11 <- newIORef 1.0
    refSlider12 <- newIORef 1.0
    refSlider13 <- newIORef (0.0, 0.0)
    refSlider14 <- newIORef (0.0, 0.0)
    refSlider15 <- newIORef 0.3
    refSlider16 <- newIORef 0.81

    refComb1 <- newIORef 0
    refPin1 <- newIORef False
    refPin2 <- newIORef False
    refPin3 <- newIORef False
    refPin4 <- newIORef False
    refPin5 <- newIORef False
    refPin6 <- newIORef False
    refPin7 <- newIORef False

    refOk1 <- newIORef 0
    refNg1 <- newIORef 0

    refOkHold1 <- newIORef False
    refNgHold1 <- newIORef False

    refReverseX <- newIORef False
    refReverseY <- newIORef True

    refItemActive1 <- newIORef False

    refPos1 <- newIORef $ ImVec2 0 0
    refSize1 <- newIORef $ ImVec2 0 0
    refRect1 <- newIORef (refPos1, refSize1)

    refPos2 <- newIORef $ ImVec2 0 0
    refSize2 <- newIORef $ ImVec2 0 0
    refRect2 <- newIORef (refPos2, refSize2)

    refPos3 <- newIORef $ ImVec2 0 0
    refSize3 <- newIORef $ ImVec2 0 0
    refRect3 <- newIORef (refPos3, refSize3)

    texId1 <- makeTexture
    texId2 <- makeTexture
    texId3 <- makeTexture

    refChan1 <- newTChanIO
    refChan2 <- newTChanIO
    refChan3 <- newTChanIO
    refChan4 <- newTChanIO

    refChan5 <- newTChanIO
    refChan6 <- newTChanIO
    refChan7 <- newTChanIO
    refChan8 <- newTChanIO

    refChan9 <- atomically $ dupTChan refChan6
    refChan10 <- atomically $ dupTChan refChan8

    refStrTuple1 <- newIORef ("", "")
    refOcrState1 <- newIORef OcrUnknown

    refStoch1 <- newIORef (0,0)
    refTrig1 <- newIORef Nothing
    refTrig2 <- newIORef Nothing
    refTrig3 <- newIORef Nothing

    refComp1 <- newIORef $ Nothing

    -- Initialization and initial input
    let init = do
          -- Initial time
          Just t0 <- getTime
          writeIORef tpRef t0

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "opengl-camera-parameters" (DragHub3 refSlider1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-preview-zoom" (DragHub1 refSlider2) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-preview-zoom" (DragHub1 refSlider11) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "camera-param-gamma" (DragHub1 refSlider3) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "camera-param-contrast" (DragHub1 refSlider4) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "camera-param-grain" (DragHub1 refSlider5) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "camera-param-sharpness" (DragHub1 refSlider6) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "camera-param-exposure" (DragHub1 refSlider7) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "opencv-canny-threshold1" (DragHub1 refSlider8) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "opencv-canny-threshold2" (DragHub1 refSlider9) ctrls)
          
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "opencv-canny-enable" (PinHub1 refPin1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-collapse-enabled" (PinHub1 refPin2) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-collapse-enabled" (PinHub1 refPin3) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "trigger-batchocr-operation" (PinHub1 refPin4) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "trigger-parameters-restore" (PinHub1 refPin5) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "motion-collapse-enabled" (PinHub1 refPin6) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "motion-approach-confirmed" (PinHub1 refPin7) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "camera-param-reverse-x" (PinHub1 refReverseX) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "camera-param-reverse-y" (PinHub1 refReverseY) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-range-select-active" (PinHub1 refItemActive1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "all-configurations-index" (CombHub1 refComb1) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "production-ok-hold" (PinHub1 refOkHold1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "production-ng-hold" (PinHub1 refNgHold1) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "production-ok-count" (CombHub1 refOk1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "production-ng-count" (CombHub1 refNg1) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-region-select" (RectHub4 refRect1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-region-select" (RectHub4 refRect2) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "motion-region-select" (RectHub4 refRect3) ctrls)
          
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-region" (TexIdHub1 texId1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-region" (TexIdHub1 texId2) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "motion-sense-region" (TexIdHub1 texId3) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-scale-factor" (DragHub1 refSlider10) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-scale-factor" (DragHub1 refSlider12) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-start" (DragHub2 refSlider13) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-start" (DragHub2 refSlider14) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "motion-sense-lag" (DragHub1 refSlider15) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "motion-trigger-threshold" (DragHub1 refSlider16) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-submit" (ChanHub1 refChan1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-collect" (ChanHub2 refChan2) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-submit" (ChanHub1 refChan3) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-collect" (ChanHub2 refChan4) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-submit-batch" (ChanHub1 refChan5) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-collect-batch" (ChanHub2 refChan6) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-submit-batch" (ChanHub1 refChan7) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-collect-batch" (ChanHub2 refChan8) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-collect-batch-dup" (ChanHub2 refChan9) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-collect-batch-dup" (ChanHub2 refChan10) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "batchocr-ultimate-results" (StrHub2 refStrTuple1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "batchocr-state-variable" (OcrHub1 refOcrState1) ctrls)

          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-stochastic-delta" (StochHub2 refStoch1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "barcode-ocr-trigger" (TrigHub1 refTrig1) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-ocr-trigger" (TrigHub1 refTrig2) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-plc-modbus-trigger" (TrigHub1 refTrig3) ctrls)
          modifyIORef' ctrlMaps (\ctrls-> Map.insert "serial-number-sequence-marker" (CompHub1 refComp1) ctrls)

          slider1 <- get refSlider1
          slider2 <- get refSlider2
          slider3 <- get refSlider3
          slider4 <- get refSlider4
          slider5 <- get refSlider5
          slider6 <- get refSlider6
          slider7 <- get refSlider7

          slider8 <- get refSlider8
          slider9 <- get refSlider9
          slider10 <- get refSlider10
          slider11 <- get refSlider11
          slider12 <- get refSlider12
          slider13 <- get refSlider13
          slider14 <- get refSlider14
          slider15 <- get refSlider15
          slider16 <- get refSlider16
          
          pin1 <- get refPin1
          pin2 <- get refPin2
          pin3 <- get refPin3
          pin4 <- get refPin4
          pin5 <- get refPin5
          pin6 <- get refPin6
          pin7 <- get refPin7
          chkbox1 <- get refReverseX
          chkbox2 <- get refReverseY
          comb1 <- get refComb1
          itemact1 <- get refItemActive1
          
          ok1 <- get refOk1
          ng1 <- get refNg1

          okhold1 <- get refOkHold1
          nghold1 <- get refNgHold1

          (pos1, size1) <- get refRect1
          (ImVec2 x1 y1) <- get pos1
          (ImVec2 w1 h1) <- get size1

          (pos2, size2) <- get refRect2
          (ImVec2 x2 y2) <- get pos2
          (ImVec2 w2 h2) <- get size2

          (pos3, size3) <- get refRect3
          (ImVec2 x3 y3) <- get pos3
          (ImVec2 w3 h3) <- get size3

          strtuple1 <- get refStrTuple1
          ocrstate1 <- get refOcrState1
          stoch1 <- get refStoch1
          trig1 <- get refTrig1
          trig2 <- get refTrig2
          trig3 <- get refTrig3
          comp1 <- get refComp1

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opengl-camera-parameters" (DragItem3 slider1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-preview-zoom" (DragItem1 slider2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-preview-zoom" (DragItem1 slider11) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-gamma" (DragItem1 slider3) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-contrast" (DragItem1 slider4) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-grain" (DragItem1 slider5) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-sharpness" (DragItem1 slider6) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-exposure" (DragItem1 slider7) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opencv-canny-threshold1" (DragItem1 slider8) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opencv-canny-threshold2" (DragItem1 slider9) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opencv-canny-enable" (PinItem1 pin1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-collapse-enabled" (PinItem1 pin2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-collapse-enabled" (PinItem1 pin3) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "trigger-batchocr-operation" (PinItem1 pin4) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "trigger-parameters-restore" (PinItem1 pin5) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-collapse-enabled" (PinItem1 pin6) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-approach-confirmed" (PinItem1 pin7) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-reverse-x" (PinItem1 chkbox1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-reverse-y" (PinItem1 chkbox2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "all-configurations-index" (CombItem1 comb1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-range-select-active" (PinItem1 itemact1) ((uiInput >>> allCtrls) a))})
          
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ok-hold" (PinItem1 okhold1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ng-hold" (PinItem1 nghold1) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ok-count" (CombItem1 ok1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ng-count" (CombItem1 ng1) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-region-select" (RectItem4 (x1,y1,w1,h1)) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-region-select" (RectItem4 (x2,y2,w2,h2)) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-region-select" (RectItem4 (x3,y3,w3,h3)) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-scale-factor" (DragItem1 slider10) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-scale-factor" (DragItem1 slider12) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-ocr-start" (DragItem2 slider13) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-ocr-start" (DragItem2 slider14) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-sense-lag" (DragItem1 slider15) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-trigger-threshold" (DragItem1 slider16) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "batchocr-ultimate-results" (StrItem2 strtuple1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "batchocr-state-variable" (OcrItem1 ocrstate1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-ocr-stochastic-delta" (StochItem2 stoch1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-ocr-trigger" (TrigItem1 trig1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-ocr-trigger" (TrigItem1 trig2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-plc-modbus-trigger" (TrigItem1 trig3) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-sequence-marker" (CompItem1 comp1) ((uiInput >>> allCtrls) a))})

          withRuntimeConfigFile "config1.scm" ReadMode $ \handle -> do
            xs <- hGetContents handle
            result <- LSC.evalString env xs
            print result
            return ()

          newInput' <- get newInput
          return newInput'

    let getTimeInput _ = do
          tp <- get tpRef
          Just t <- getTime
          let dt = if t > tp then (t-tp) else 0.001
          writeIORef tpRef t
          
          slider1 <- get refSlider1
          slider2 <- get refSlider2
          slider3 <- get refSlider3
          slider4 <- get refSlider4
          slider5 <- get refSlider5
          slider6 <- get refSlider6
          slider7 <- get refSlider7

          slider8 <- get refSlider8
          slider9 <- get refSlider9
          slider10 <- get refSlider10
          slider11 <- get refSlider11
          slider12 <- get refSlider12
          slider13 <- get refSlider13
          slider14 <- get refSlider14
          slider15 <- get refSlider15
          slider16 <- get refSlider16

          pin1 <- get refPin1
          pin2 <- get refPin2
          pin3 <- get refPin3
          pin4 <- get refPin4
          pin5 <- get refPin5
          pin6 <- get refPin6
          pin7 <- get refPin7
          chkbox1 <- get refReverseX
          chkbox2 <- get refReverseY
          comb1 <- get refComb1
          itemact1 <- get refItemActive1

          ok1 <- get refOk1
          ng1 <- get refNg1

          okhold1 <- get refOkHold1
          nghold1 <- get refNgHold1

          (pos1, size1) <- get refRect1
          (ImVec2 x1 y1) <- get pos1
          (ImVec2 w1 h1) <- get size1

          (pos2, size2) <- get refRect2
          (ImVec2 x2 y2) <- get pos2
          (ImVec2 w2 h2) <- get size2

          (pos3, size3) <- get refRect3
          (ImVec2 x3 y3) <- get pos3
          (ImVec2 w3 h3) <- get size3

          strtuple1 <- get refStrTuple1
          ocrstate1 <- get refOcrState1
          stoch1 <- get refStoch1
          trig1 <- get refTrig1
          trig2 <- get refTrig2
          trig3 <- get refTrig3
          comp1 <- get refComp1

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opengl-camera-parameters" (DragItem3 slider1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-preview-zoom" (DragItem1 slider2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-preview-zoom" (DragItem1 slider11) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-gamma" (DragItem1 slider3) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-contrast" (DragItem1 slider4) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-grain" (DragItem1 slider5) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-sharpness" (DragItem1 slider6) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-exposure" (DragItem1 slider7) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opencv-canny-threshold1" (DragItem1 slider8) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opencv-canny-threshold2" (DragItem1 slider9) ((uiInput >>> allCtrls) a))})
          
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "opencv-canny-enable" (PinItem1 pin1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-collapse-enabled" (PinItem1 pin2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-collapse-enabled" (PinItem1 pin3) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "trigger-batchocr-operation" (PinItem1 pin4) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "trigger-parameters-restore" (PinItem1 pin5) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-collapse-enabled" (PinItem1 pin6) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-approach-confirmed" (PinItem1 pin7) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-reverse-x" (PinItem1 chkbox1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "camera-param-reverse-y" (PinItem1 chkbox2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "all-configurations-index" (CombItem1 comb1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-range-select-active" (PinItem1 itemact1) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ok-hold" (PinItem1 okhold1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ng-hold" (PinItem1 nghold1) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ok-count" (CombItem1 ok1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "production-ng-count" (CombItem1 ng1) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-region-select" (RectItem4 (x1,y1,w1,h1)) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-region-select" (RectItem4 (x2,y2,w2,h2)) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-region-select" (RectItem4 (x3,y3,w3,h3)) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-scale-factor" (DragItem1 slider10) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-scale-factor" (DragItem1 slider12) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-ocr-start" (DragItem2 slider13) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-ocr-start" (DragItem2 slider14) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-sense-lag" (DragItem1 slider15) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "motion-trigger-threshold" (DragItem1 slider16) ((uiInput >>> allCtrls) a))})

          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "batchocr-ultimate-results" (StrItem2 strtuple1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "batchocr-state-variable" (OcrItem1 ocrstate1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-ocr-stochastic-delta" (StochItem2 stoch1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "barcode-ocr-trigger" (TrigItem1 trig1) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-ocr-trigger" (TrigItem1 trig2) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-plc-modbus-trigger" (TrigItem1 trig3) ((uiInput >>> allCtrls) a))})
          modifyIORef' newInput (\a -> a {uiInput = CtrlData (Map.insert "serial-number-sequence-marker" (CompItem1 comp1) ((uiInput >>> allCtrls) a))})

          newInput' <- get newInput
          return (dt, Just newInput')
 
    return (init, getTimeInput, readIORef closedRef)
  where
    errInitNotCalled = intErr "RSAnimate"
                                "mkInitAndGetTimeInput"
                                  "Init procedure not called."




debug :: Bool
debug = True

dumpError :: String -> IO ()
dumpError str = do
  when debug $ do
    code <- glGetError
    unless (code == 0) $ do
      print code
      putStrLn str
      exitFailure
