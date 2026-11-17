{-# LANGUAGE Arrows #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE BlockArguments #-}

{-
******************************************************************************
*                              I N V A D E R S                               *
*                                                                            *
*       Module:         ObjectBehavior                                       *
*       Purpose:        Behavior of objects.                                 *
*       Author:         Henrik Nilsson                                       *
*                                                                            *
*             Copyright (c) Yale University, 2003                            *
*                                                                            *
******************************************************************************
-}

module ObjectBehavior (
   combineAll
) where

import qualified ProductionLog as PL

import RuntimePaths
import EngravingCompare

import           FRP.Yampa
import           Object
import           Parser
import           Data.IORef
import           Control.Monad (when, void, unless)
import           Graphics.GL
import           Graphics.UI.GLFW  hiding (getWindowPos, getWindowSize)
import qualified Data.Map.Strict as Map
import           Graphics.GL
import           Language.Scheme.Types hiding (after)
import qualified Language.Scheme.Core as LSC

import           System.IO
import           System.Exit
import           Foreign.C.String
import           Foreign.Marshal.Alloc
import           Foreign.Ptr
import           Data.Word
import           Data.Char
import           Data.Maybe (isNothing, isJust, maybe, fromJust)

import           TextRecog
import           Barcode
import           Text.RawString.QQ
import           Text.Printf

import           DearImGui
import           DearImGui.Internal.Text (Text)
import qualified Data.Text as T
import qualified DearImGui.Raw as Raw
import qualified DearImGui.Raw.DrawList as DrawList

import           Device.Camera.Mindvision
import           Linear.V2 (V2(..))
import           Control.Exception
import           Control.Concurrent
import           Control.Concurrent.STM

import           Foreign hiding (void)
import           Foreign.Marshal.Alloc
import           Foreign.Ptr
import           Foreign.Storable
import           Debug.Trace
import qualified Text.Read as R

import OpenCV hiding (Font, Event)
import OpenCV.Core.Types
import OpenCV.Internal
import OpenCV.Internal.C.Inline ( openCvCtx )
import OpenCV.Internal.C.Types
import OpenCV.Internal.Core.ArrayOps
import OpenCV.Internal.Core.Types ( withArrayPtr, Scalar )
import OpenCV.Internal.Core.Types.Mat
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException )
import OpenCV.TypeLevel
import Control.Monad.Trans.Except
import OpenCV.Video.MotionAnalysis
import Control.Monad.Primitive

import Data.Time

import Data.StateVar
  ( HasGetter(get), HasSetter, ($=!) )


type ChainSF = (Env -> IORef CtrlRef -> (FontSet Font) -> (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))
type ChainSF2 = (Env -> IORef CtrlRef -> (FontSet Font) -> (BackgroundSubtractorMOG2 (PrimState IO)) -> PPOCR -> (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))
type ChainSF3 = (Env -> IORef CtrlRef -> (FontSet Font) -> (BackgroundSubtractorMOG2 (PrimState IO)) -> (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))
type RegulSF = (Env -> IORef CtrlRef -> (FontSet Font) -> IO ())
type RegulSF2 = (Env -> IORef CtrlRef -> (FontSet Font) -> (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO ())

combineAll :: RandomGen g => g -> ComparisonRuntime -> SF GameInput ((Env -> GLuint -> IORef CtrlRef -> FontSet Font -> IO ()), RegulSF, RegulSF, (Env -> IO ()), RegulSF, RegulSF, ChainSF, ChainSF, ChainSF2, RegulSF, ChainSF3)
combineAll g runtime = proc oi -> do
  a <- bootStrap -< oi
  b <- showConsole -< oi
  c <- cameraParams -< oi
  d <- sentinel -< oi
  e <- selectConfig -< oi
  f <- saveConfig -< oi
  let g = \_ _ _ src -> pure src
  let h = \_ _ _ src -> pure src
  i <- serialNumOCR runtime -< oi
  j <- overLord runtime -< oi
  let k = \_ _ _ _ src -> pure src
  returnA -< (a, b, c, d, e, f, g, h, i, j, k)


holdAfter :: Double -> String -> SF GameInput Bool
holdAfter d name = myAux Init
  where
    myAux sg = switch (holdAfter' sg d name) myAux

holdAfter' :: Stage -> Double -> String -> SF GameInput (Bool, Event Stage)
holdAfter' sg d name = proc oi -> do
  let (Just (PinItem1 b10)) = Map.lookup name (giCtrl oi)

  fire <- after d () -< ()
  evt <- edge -< b10

  let ae = gate (Event (Running 1)) (sg == Init && isEvent evt)
      be = gate (Event Init) (sg == (Running 1) && not b10)
      ce = gate (Event (Running 2)) (sg == (Running 1) && isEvent fire)
      de = gate (Event Init) (sg == (Running 2))
      oe = mergeEvents [ae,be,ce,de]

  oe' <- iPre noEvent -< oe
  returnA -< ((sg == (Running 2)) , oe')


bootStrap :: SF GameInput (Env -> GLuint -> IORef CtrlRef -> FontSet Font -> IO ())
bootStrap = myAux Init
  where
    myAux sg = dSwitch (bootStrap' sg) myAux

bootStrap' :: Stage -> SF GameInput ((Env -> GLuint -> IORef CtrlRef -> FontSet Font -> IO ()), Event Stage)
bootStrap' sg = proc oi -> do
  let (Just (CombItem1 b20)) = Map.lookup "production-ok-count" (giCtrl oi)
      (Just (CombItem1 b21)) = Map.lookup "production-ng-count" (giCtrl oi)

  ngcls <- holdAfter 3.0 "production-ng-hold" >>> edge -< oi

  let ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]
      (Just (DragItem3 (b9,b10,b11))) = Map.lookup "opengl-camera-parameters" (giCtrl oi)

  oe' <- iPre noEvent -< oe

  (_, changed) <- trackFloat3 -< (b9,b10,b11)

  returnA -< ((\env shader ctrlMaps fontSet-> do
                 let FontSet{..} = fontSet
                 ctrlMaps' <- get ctrlMaps
                 let (Just (DragHub3 ref)) = Map.lookup "opengl-camera-parameters" ctrlMaps'
                 when (sg == Init) $ do
                   (b9,b10,b11) <- get ref
                   setFloat shader  "mixValue" b9
                   LSC.evalString env $ "(set! yy " ++ show b10 ++ ")"
                   void $ LSC.evalString env $ "(set! zz " ++ show (b11*100) ++ ")"

                 when (sg == (Running 1)) $ do
                   let (Just (PinHub1 okhold)) = Map.lookup "production-ok-hold" ctrlMaps'
                       (Just (PinHub1 nghold)) = Map.lookup "production-ng-hold" ctrlMaps'
                       (Just (CombHub1 ng)) = Map.lookup "production-ng-count" ctrlMaps'

                   when (isEvent ngcls) $
                     ng $=! 0

                   pos <- newIORef $ ImVec2 16 16
                   mypos <- newIORef $ ImVec2 0.96 0.9
                   color3 <- newIORef $ ImVec4 0.897 0.085 0.2 1.0
                   color4 <- newIORef $ ImVec4 0.191 0.793 0.118 1.0
                   color5 <- newIORef $ ImVec4 0.0 0.0 0.0 0.1
                   color6 <- newIORef $ ImVec4 0.796 0.053 0.112 1.0
                   color7 <- newIORef $ ImVec4 0.192 0.173 0.712 1.0

                   pushFont notoFont
                   withStyleVar ImGuiStyleVar_SelectableTextAlign mypos $ do
                     withStyleColor ImGuiCol_Text color4 $ do
                       withID (1 :: Int) $ selectableWith (SelectableOptions {selected = False, flags = ImGuiSelectableFlags_None, size = ImVec2 140 60}) (T.pack $ show b20)

                   k <- isItemActive
                   okhold $=! k

                   sameLine
                   pushFont droidFont2
                   withStyleColor ImGuiCol_Text color7 $ do
                     text "ok"
                   popFont

                   sameLine
                   -- dummy pos
                   sameLine

                   withStyleVar ImGuiStyleVar_SelectableTextAlign mypos $ do
                     withStyleColor ImGuiCol_Text color3 $ do
                       withID (2 :: Int) $ selectableWith (SelectableOptions {selected = False, flags = ImGuiSelectableFlags_None, size = ImVec2 80 60}) (T.pack $ show b21)

                   popFont

                   k <- isItemActive
                   nghold $=! k
                   
                   sameLine
                   pushFont droidFont2
                   withStyleColor ImGuiCol_Text color7 $ do
                     text "ng"
                   popFont

                   dragFloat3 "(?)" ref 0.003 0.0 1.0
                   sameLine
                   showHelp msyhlFont $ T.pack captionHelp
                   if changed then do
                     setFloat shader  "mixValue" b9
                     LSC.evalString env $ "(set! yy " ++ show b10 ++ ")"
                     void $ LSC.evalString env $ "(set! zz " ++ show (b11*100) ++ ")"
                     else return ()

                   k <- getFPS
                   pushFont droidFont2
                   withStyleColor ImGuiCol_Text (if k > 30 then color4 else color6) $ do
                     text $ (T.pack $ "FPS: " ++ (take 5 $ show k))
                   popFont
             ), oe')

  where
    trackFloat3 = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) ((0.0,0.0,0.0), False)

showConsole :: SF GameInput RegulSF
showConsole = myAux Init
  where
    myAux sg = dSwitch (showConsole' sg) myAux

showConsole' :: Stage -> SF GameInput (RegulSF, Event Stage)
showConsole' sg = proc oi -> do
  let ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]

  oe' <- iPre noEvent -< oe
  returnA -< ((\env ctrlMaps fontSet ->
                  bracket_ (pushFont (msyhlFont fontSet)) popFont $ do
                    ctrlMaps' <- get ctrlMaps
                    let (Just (ChanHub2 ser)) = Map.lookup "serial-number-ocr-collect" ctrlMaps'
                        (Just (ChanHub2 bar)) = Map.lookup "barcode-ocr-collect" ctrlMaps'
                        (Just (ChanHub2 ser_batch_dup)) = Map.lookup "serial-number-ocr-collect-batch-dup" ctrlMaps'
                        (Just (ChanHub2 bar_batch_dup)) = Map.lookup "barcode-ocr-collect-batch-dup" ctrlMaps'

                    case sg of
                      Init -> do
                        showAppLog ""

                      (Running 1) -> do
                        r1 <- atomically $ tryReadTChan ser
                        r2 <- atomically $ tryReadTChan bar
                        r3 <- atomically $ tryReadTChan ser_batch_dup
                        r4 <- atomically $ tryReadTChan bar_batch_dup
                        timeStamp <- formatTime defaultTimeLocale "%Y-%m-%d-%H:%M:%S" <$> getCurrentTime
                        let r1' = (maybe "" ("[刻字]: " ++) r1)
                            r2' = (maybe "" ("[刻字]: " ++) r2)
                            r3' = (maybe "" (\a-> timeStamp ++ "[刻字]: " ++ a) r3)
                            r4' = (maybe "" (\a-> timeStamp ++ "[刻字]: " ++ a) r4)
                        showAppLog (r1' ++ r2' ++ r3' ++ r4')

              ), oe')


overLord :: ComparisonRuntime -> SF GameInput RegulSF
overLord runtime = proc oi -> do
  clearOk <- holdAfter 3.0 "production-ok-hold" >>> edge -< oi
  returnA -< (\env ctrlMaps fontSet -> do
    refs <- get ctrlMaps
    let Just (CombHub1 ok) = Map.lookup "production-ok-count" refs
    when (isEvent clearOk) $ ok $=! 0
    bracket_ (pushFont (msyhlFont fontSet)) popFont $
      bracket_ (begin3 "刻字比对结果") end $ do
        text "预设文字："
        readIORef (comparisonPreset runtime) >>= text
        pending <- readIORef (comparisonPending runtime)
        when (isJust pending) $ text "正在识别，请等待检测完成"
        result <- readIORef (comparisonLastResult runtime)
        case result of
          Nothing -> text "等待检测"
          Just value -> do
            text "识别文字："
            text (T.pack (recognizedText value))
            text (T.pack ((if comparisonPassed value then "OK " else "NG ") ++ comparisonDetail value)))

dragFloat' :: (HasSetter ref Float, HasGetter ref Float) => Env -> (Float, Bool) -> Text -> ref -> Float -> Float -> Float -> IO ()
dragFloat' env (val, changed) target ref speed minValue maxValue = do
  dragFloat target ref speed minValue maxValue
  if changed then
    void $ LSC.evalString env (printf fmtString target val)
    else return ()

checkbox' :: (HasSetter ref Bool, HasGetter ref Bool) => Env -> (Bool, Bool) -> Text -> ref -> IO ()
checkbox' env (pin, changed) target ref = do
  checkbox target ref
  if changed then
    void $ LSC.evalString env (printf fmtString target ((if pin == True then 1.0 else 0.0)::Float))
    else return ()
  return ()

cameraParams :: SF GameInput RegulSF
cameraParams = myAux Init
  where
    myAux sg = dSwitch (cameraParams' sg) myAux

cameraParams' :: Stage -> SF GameInput (RegulSF, Event Stage)
cameraParams' sg = proc oi -> do
  let (Just (DragItem1 b10)) = Map.lookup "camera-param-gamma" (giCtrl oi)
      (Just (DragItem1 b11)) = Map.lookup "camera-param-contrast" (giCtrl oi)
      (Just (DragItem1 b12)) = Map.lookup "camera-param-grain" (giCtrl oi)
      (Just (DragItem1 b13)) = Map.lookup "camera-param-sharpness" (giCtrl oi)
      (Just (DragItem1 b14)) = Map.lookup "camera-param-exposure" (giCtrl oi)
      (Just (PinItem1 rx)) = Map.lookup "camera-param-reverse-x" (giCtrl oi)
      (Just (PinItem1 ry)) = Map.lookup "camera-param-reverse-y" (giCtrl oi)
      (Just (CombItem1 b30)) = Map.lookup "all-configurations-index" (giCtrl oi)

      ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]

  oe' <- iPre noEvent -< oe
  (val, changed) <- trackInt -< b30

  b10' <- trackFloat -< b10
  b11' <- trackFloat -< b11
  b12' <- trackFloat -< b12
  b13' <- trackFloat -< b13
  b14' <- trackFloat -< b14

  rx' <- trackBool -< rx
  ry' <- trackBool -< ry

  returnA -< ((\env ctrlMaps fontSet-> do
              let setFloat :: (HasGetter ref Float) => String -> ref -> IO ()
                  setFloat name floatValue = do
                    val <- get floatValue
                    void $ LSC.evalString env (printf fmtString name val)
                  setBool :: (HasGetter ref Bool) => String -> ref -> IO ()
                  setBool name boolValue = do
                    pin <- get boolValue
                    void $ LSC.evalString env (printf fmtString name ((if pin == True then 1.0 else 0.0)::Float))

              when changed $ do
                ctrlMaps' <- get ctrlMaps
                let (Just (DragHub1 gamma)) = Map.lookup "camera-param-gamma" ctrlMaps'
                    (Just (DragHub1 contrast)) = Map.lookup "camera-param-contrast" ctrlMaps'
                    (Just (DragHub1 grain)) = Map.lookup "camera-param-grain" ctrlMaps'
                    (Just (DragHub1 sharpness)) = Map.lookup "camera-param-sharpness" ctrlMaps'
                    (Just (DragHub1 exposure)) = Map.lookup "camera-param-exposure" ctrlMaps'
                    (Just (PinHub1 reversex)) = Map.lookup "camera-param-reverse-x" ctrlMaps'
                    (Just (PinHub1 reversey)) = Map.lookup "camera-param-reverse-y" ctrlMaps'

                setFloat "Gamma" gamma
                setFloat "Contrast" contrast
                setFloat "Grain" grain
                setFloat "Sharpness" sharpness
                setFloat "Exposure" exposure
                setBool "ReverseX" reversex
                setBool "ReverseY" reversey
                return ()

              let FontSet{..} = fontSet
              pushFont msyhlFont
              result <- collapsingHeader "相机参数"
              popFont
              
              pushFont droidFont
              when result $ do
                ctrlMaps' <- get ctrlMaps
                let (Just (DragHub1 gamma)) = Map.lookup "camera-param-gamma" ctrlMaps'
                    (Just (DragHub1 contrast)) = Map.lookup "camera-param-contrast" ctrlMaps'
                    (Just (DragHub1 grain)) = Map.lookup "camera-param-grain" ctrlMaps'
                    (Just (DragHub1 sharpness)) = Map.lookup "camera-param-sharpness" ctrlMaps'
                    (Just (DragHub1 exposure)) = Map.lookup "camera-param-exposure" ctrlMaps'
                    (Just (PinHub1 reversex)) = Map.lookup "camera-param-reverse-x" ctrlMaps'
                    (Just (PinHub1 reversey)) = Map.lookup "camera-param-reverse-y" ctrlMaps'
              
                -- print $ "Stage :" ++ show sg
                dragFloat' env b10' "Gamma" gamma 1.0 1.0 240.0
                sameLine
                showHelp msyhlFont "伽马参数：调整图像的明暗。光源亮度高，数值可以往高调，让图像不至于过曝。光源亮度低，数值可以往低调，让图像不至于过暗"
                dragFloat' env b11' "Contrast" contrast 1.0 1.0 190.0
                sameLine
                showHelp msyhlFont "对比度：和伽马参数配合调整，伽马参数尽量往低调，对比度尽量往高调"
                dragFloat' env b12' "Grain" grain 1.0 1.0 4.0
                sameLine
                showHelp msyhlFont "CCD感光增益：有4个档，数值越大，图像越亮，但同时干扰也大。图像过暗，尽量通过调整镜头上的光圈大小和相机曝光时间来提高图像亮度"
                dragFloat' env b13' "Sharpness" sharpness 1.0 1.0 90.0
                sameLine
                showHelp msyhlFont "图像锐度：这个数值尽量保持为1，数值大了非常影响OCR识别率"
                dragFloat' env b14' "Exposure" exposure 500.0 5000.0 50000.0
                sameLine
                showHelp msyhlFont "CCD曝光时间：曝光时间越长，相机帧率越低，OCR识别速度越慢。尽量将这个参数控制在比较小的数值，通过调整镜头上的光圈来提高图像亮度"

                checkbox' env rx' "ReverseX" reversex
                sameLine
                showHelp msyhlFont "图像沿X轴翻转"
                sameLine
                checkbox' env ry' "ReverseY" reversey
                sameLine
                showHelp msyhlFont "图像沿Y轴翻转"
              popFont
            ), oe')
  where
    trackFloat = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (0.0, False)
    trackBool = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (False, False)
    trackInt = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (1, False)


setFloat :: GLuint -> String -> GLfloat -> IO ()
setFloat id' name val = do
  withCString name $ \cstr -> do
    location <- glGetUniformLocation id' cstr
    glUniform1f location val




sentinel :: SF GameInput (Env -> IO ())
sentinel = myAux Init
  where
    myAux sg = dSwitch (sentinel' sg) myAux

sentinel' :: Stage -> SF GameInput ((Env -> IO ()), Event Stage)
sentinel' sg = proc oi -> do
  evt <- repeatedly 2.0 () -< ()
  let ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]

  oe' <- iPre noEvent -< oe
  returnA -< ((\env -> do
                  r <- LSC.evalString env "mycam"
                  when (r == "0" && isEvent evt) $ do
                    print $ "mycam: " ++ r
                    -- void $ LSC.evalString env "(begin (set! mycam (init-my-camera \"MV-SUA131GC#0\")) mycam)"
                    -- void $ LSC.evalString env "(begin (set! mycam (init-my-camera \"Hikvision\")) mycam)"
                  ), oe')


combo' :: (HasGetter ref Int, HasSetter ref Int) => Env -> Bool -> (Int, Bool) -> Text -> ref -> [Text] -> IO ()
combo' env restore (val, changed) label selectedIndex items = do
  combo label selectedIndex items
  when changed $ do
    withRuntimeConfigFile ("config" ++ show (val+1) ++ ".scm") ReadMode $ \handle -> do
      xs <- hGetContents handle
      result <- LSC.evalString env xs
      print result

  when restore $ do
    withRuntimeConfigFile ("config" ++ show (val+1) ++ ".scm") ReadMode $ \handle -> do
      xs <- hGetContents handle
      result <- LSC.evalString env xs
      print result

selectConfig :: SF GameInput RegulSF
selectConfig = myAux Init
  where
    myAux sg = dSwitch (selectConfig' sg) myAux

selectConfig' :: Stage -> SF GameInput (RegulSF, Event Stage)
selectConfig' sg = proc oi -> do
  let (Just (CombItem1 b10)) = Map.lookup "all-configurations-index" (giCtrl oi)
      (Just (PinItem1 b20)) = Map.lookup "trigger-parameters-restore" (giCtrl oi)
      ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]

  oe' <- iPre noEvent -< oe
  b10' <- trackInt -< b10
  restore <- edge -< b20

  returnA -< ((\env ctrlMaps fontSet -> do
                  let FontSet{..} = fontSet
                  pushFont msyhlFont
                  ctrlMaps' <- get ctrlMaps
                  let (Just (CombHub1 selected)) = Map.lookup "all-configurations-index" ctrlMaps'
                  combo' env (isEvent restore) b10' "参数列表" selected [ "1", "2", "3" ]
                  sameLine
                  showHelp msyhlFont "可以记忆3组OCR程序参数，包括相机参数，识别区域，OCR算法参数，生产ok ng数量"
                  popFont
                  return ()
                  ), oe')

  where
    trackInt = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (1, False)



saveConfig :: SF GameInput RegulSF
saveConfig = myAux Init
  where
    myAux sg = dSwitch (saveConfig' sg) myAux

saveConfig' :: Stage -> SF GameInput (RegulSF, Event Stage)
saveConfig' sg = proc oi -> do
  let (Just (DragItem1 b10)) = Map.lookup "camera-param-gamma" (giCtrl oi)
      (Just (DragItem1 b11)) = Map.lookup "camera-param-contrast" (giCtrl oi)
      (Just (DragItem1 b12)) = Map.lookup "camera-param-grain" (giCtrl oi)
      (Just (DragItem1 b13)) = Map.lookup "camera-param-sharpness" (giCtrl oi)
      (Just (DragItem1 b14)) = Map.lookup "camera-param-exposure" (giCtrl oi)
      (Just (DragItem1 b15)) = Map.lookup "opencv-canny-threshold1" (giCtrl oi)
      (Just (DragItem1 b16)) = Map.lookup "opencv-canny-threshold2" (giCtrl oi)
      (Just (PinItem1 b17)) = Map.lookup "opencv-canny-enable" (giCtrl oi)
      (Just (DragItem1 b18)) = Map.lookup "serial-number-scale-factor" (giCtrl oi)
      (Just (DragItem1 b19)) = Map.lookup "serial-number-preview-zoom" (giCtrl oi)
      (Just (DragItem1 b23)) = Map.lookup "barcode-scale-factor" (giCtrl oi)
      (Just (DragItem1 b24)) = Map.lookup "barcode-preview-zoom" (giCtrl oi)
      (Just (DragItem1 b25)) = Map.lookup "motion-sense-lag" (giCtrl oi)
      (Just (DragItem1 b26)) = Map.lookup "motion-trigger-threshold" (giCtrl oi)

      (Just (PinItem1 rx)) = Map.lookup "camera-param-reverse-x" (giCtrl oi)
      (Just (PinItem1 ry)) = Map.lookup "camera-param-reverse-y" (giCtrl oi)

      (Just (DragItem3 (b20,b21,b22))) = Map.lookup "opengl-camera-parameters" (giCtrl oi)
      (Just (CombItem1 b30)) = Map.lookup "all-configurations-index" (giCtrl oi)
      (Just (RectItem4 (b40,b41,b42,b43))) = Map.lookup "serial-number-region-select" (giCtrl oi)
      (Just (RectItem4 (b44,b45,b46,b47))) = Map.lookup "barcode-region-select" (giCtrl oi)
      (Just (RectItem4 (b50,b51,b52,b53))) = Map.lookup "motion-region-select" (giCtrl oi)

      (Just (DragItem2 (b60,b61))) = Map.lookup "serial-number-ocr-start" (giCtrl oi)
      (Just (DragItem2 (b62,b63))) = Map.lookup "barcode-ocr-start" (giCtrl oi)

      (Just (CombItem1 b70)) = Map.lookup "production-ok-count" (giCtrl oi)
      (Just (CombItem1 b71)) = Map.lookup "production-ng-count" (giCtrl oi)

      ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]

  oe' <- iPre noEvent -< oe
  (val, changed) <- trackInt -< b30

  returnA -< ((\env ctrlMaps fontSet-> do
                  let FontSet{..} = fontSet
                  pushFont msyhlFont
                  separator
                  clicked <- button "保存参数"
                  sameLine
                  showHelp msyhlFont "保存当前配置的所有参数，如果临时调整了参数，想进行快速还原，可以按x键"
                  when clicked $ do
                    refs <- get ctrlMaps
                    let Just (CombHub1 selectedProfile) = Map.lookup "all-configurations-index" refs
                    profile <- get selectedProfile
                    withRuntimeConfigFile ("config" ++ show (profile+1) ++ ".scm") WriteMode $ \handle -> do
                      hPrintf handle "(begin\n"
                      hPrintf handle configTemplate1 ("camera-param-gamma"::String) (b10::Float)
                      hPrintf handle configTemplate1 ("camera-param-contrast"::String) (b11::Float)
                      hPrintf handle configTemplate1 ("camera-param-grain"::String) (b12::Float)
                      hPrintf handle configTemplate1 ("camera-param-sharpness"::String) (b13::Float)
                      hPrintf handle configTemplate1 ("camera-param-exposure"::String) (b14::Float)

                      hPrintf handle configTemplate1 ("opencv-canny-threshold1"::String) (b15::Float)
                      hPrintf handle configTemplate1 ("opencv-canny-threshold2"::String) (b16::Float)
                      hPrintf handle configTemplate1 ("serial-number-scale-factor"::String) (b18::Float)
                      hPrintf handle configTemplate1 ("serial-number-preview-zoom"::String) (b19::Float)
                      hPrintf handle configTemplate1 ("barcode-scale-factor"::String) (b23::Float)
                      hPrintf handle configTemplate1 ("barcode-preview-zoom"::String) (b24::Float)
                      hPrintf handle configTemplate1 ("motion-sense-lag"::String) (b25::Float)
                      hPrintf handle configTemplate1 ("motion-trigger-threshold"::String) (b26::Float)

                      hPrintf handle configTemplate3 ("opencv-canny-enable"::String) (if b17 then "#t"::String else "#f"::String)

                      hPrintf handle configTemplate2 ("opengl-camera-parameters"::String) (b20::Float) (b21::Float) (b22::Float)
                      hPrintf handle configTemplate3 ("camera-param-reverse-x"::String) (if rx then "#t"::String else "#f"::String)
                      hPrintf handle configTemplate3 ("camera-param-reverse-y"::String) (if ry then "#t"::String else "#f"::String)

                      hPrintf handle configTemplate4 ("serial-number-region-select"::String) (b40::Float) (b41::Float) (b42::Float) (b43::Float)
                      hPrintf handle configTemplate4 ("barcode-region-select"::String) (b44::Float) (b45::Float) (b46::Float) (b47::Float)
                      hPrintf handle configTemplate4 ("motion-region-select"::String) (b50::Float) (b51::Float) (b52::Float) (b53::Float)

                      hPrintf handle configTemplate5 ("serial-number-ocr-start"::String) (b60::Float) (b61::Float)
                      hPrintf handle configTemplate5 ("barcode-ocr-start"::String) (b62::Float) (b63::Float)

                      hPrintf handle configTemplate6 ("production-ok-count"::String) (b70::Int)
                      hPrintf handle configTemplate6 ("production-ng-count"::String) (b71::Int)
                      refs <- get ctrlMaps
                      let Just (TextHub1 preset) = Map.lookup "engraving-expected-text" refs
                      expected <- get preset
                      hPutStrLn handle ("  (load-system-property all-controls-references \"engraving-expected-text\" " ++ schemeString (T.unpack expected) ++ ")")
                      hPrintf handle ")"
                    persistRuntimeProfile profile
                    let Just (ChanHub2 logChannel) = Map.lookup "serial-number-ocr-collect" refs
                    atomically $ writeTChan logChannel "[设置] 参数和预设文字已保存，下次启动自动恢复\n"
                  popFont
                  ), oe')

  where
    trackInt = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (1, False)


serialNumOCR :: ComparisonRuntime -> SF GameInput ChainSF2
serialNumOCR runtime = myAux Init
  where
    myAux sg = dSwitch (serialNumOCR' runtime sg) myAux

serialNumOCR' :: ComparisonRuntime -> Stage -> SF GameInput (ChainSF2, Event Stage)
serialNumOCR' runtime sg = proc oi -> do
  let (Just (RectItem4 (x,y,w,h))) = Map.lookup "serial-number-region-select" (giCtrl oi)
      (Just (PinItem1 b20)) = Map.lookup "serial-number-collapse-enabled" (giCtrl oi)
      (Just (PinItem1 b21)) = Map.lookup "trigger-batchocr-operation" (giCtrl oi)
      (Just (PinItem1 b22)) = Map.lookup "trigger-parameters-restore" (giCtrl oi)
      (Just (CombItem1 b30)) = Map.lookup "all-configurations-index" (giCtrl oi)
      (Just (DragItem1 b10)) = Map.lookup "serial-number-preview-zoom" (giCtrl oi)
      (Just (DragItem1 b11)) = Map.lookup "serial-number-scale-factor" (giCtrl oi)
      (Just (DragItem2 (b40,b41))) = Map.lookup "serial-number-ocr-start" (giCtrl oi)
      (Just (StochItem2 (b12,b13))) = Map.lookup "serial-number-ocr-stochastic-delta" (giCtrl oi)

  let ae = gate (Event (Running 1)) (sg == Init)
      be = gate (Event (Running 2)) (sg == (Running 1) && b20 == True)
      ce = gate (Event (Running 1)) (sg == (Running 2) && b20 == False)
      oe = mergeEvents [ae,be,ce]

  oe' <- iPre noEvent -< oe
  (val, changed) <- trackInt -< b30
  b21' <- edge -< b21
  restore <- edge -< b22

  isGen <- iPre NoEvent >>> once -< gate (Event Bool) (sg == Init)

  returnA -< ((\env ctrlMaps fontSet backSub ocr src -> do
                  ctrlMaps' <- get ctrlMaps
                  let (Just (RectHub4 win)) = Map.lookup "serial-number-region-select" ctrlMaps'
                      (Just (PinHub1 col)) = Map.lookup "serial-number-collapse-enabled" ctrlMaps'
                      (Just (TexIdHub1 texId)) = Map.lookup "serial-number-ocr-region" ctrlMaps'
                      (Just (DragHub1 ratio)) = Map.lookup "serial-number-preview-zoom" ctrlMaps'
                      (Just (DragHub1 scale)) = Map.lookup "serial-number-scale-factor" ctrlMaps'
                      (Just (ChanHub1 submit)) = Map.lookup "serial-number-ocr-submit" ctrlMaps'
                      (Just (ChanHub2 collect)) = Map.lookup "serial-number-ocr-collect" ctrlMaps'
                      (Just (ChanHub1 submit_batch)) = Map.lookup "serial-number-ocr-submit-batch" ctrlMaps'
                      (Just (ChanHub2 collect_batch)) = Map.lookup "serial-number-ocr-collect-batch" ctrlMaps'
                      (Just (OcrHub1 ocrState)) = Map.lookup "batchocr-state-variable" ctrlMaps'
                      (Just (DragHub2 rx)) = Map.lookup "serial-number-ocr-start" ctrlMaps'
                      (Just (CombHub1 selectedProfile)) = Map.lookup "all-configurations-index" ctrlMaps'
                      (Just (CombHub1 ok)) = Map.lookup "production-ok-count" ctrlMaps'
                      (Just (CombHub1 ng)) = Map.lookup "production-ng-count" ctrlMaps'

                  (pos,size) <- get win

                  when changed $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always

                  when (isEvent restore) $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always

                  liveProfile <- get selectedProfile
                  syncComparisonSettings runtime liveProfile
                  completed <- pollComparison runtime
                  case completed of
                    Nothing -> return ()
                    Just (InspectionDiscarded production inspection) -> do
                      when production $ do
                        PL.recordProduction $ (PL.productionEvent "Engraving+Compare" False)
                          { PL.eventPreset = expectedText inspection, PL.eventDetected = recognizedText inspection
                          , PL.eventReason = "预设文字或参数列表已改变，旧检测结果已丢弃" }
                        ocrState $=! OcrFail
                        modifyIORef' ng (+1)
                        modbusNg
                      atomically $ writeTChan collect_batch "NG 预设文字或参数列表已改变，旧检测结果已丢弃，请重新触发\n"
                    Just (InspectionCompleted production inspection) -> do
                      atomically $ writeTChan (if production then collect_batch else collect) (formatComparison inspection)
                      when production $ do
                        PL.recordProduction $ (PL.productionEvent "Engraving+Compare" (comparisonPassed inspection))
                          { PL.eventPreset = expectedText inspection, PL.eventDetected = recognizedText inspection
                          , PL.eventReason = comparisonDetail inspection }
                        if comparisonPassed inspection then do
                          ocrState $=! OcrPass
                          modifyIORef' ok (+1)
                          modbusOk
                        else do
                          ocrState $=! OcrFail
                          modifyIORef' ng (+1)
                          modbusNg

                  let subRect = toRect $ HRect (V2 ((round x)+(round b40)+fromIntegral b12) ((round y)+(round b41)+fromIntegral b13)) (V2 (round (w/b10)) (round (h/b10)))
                      r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                      submitInspection production = do
                        image <- case r of
                          Left _ -> pure (Left "刻字识别区域无效，请重新选择")
                          Right value -> Right <$> cloneMatM value
                        let recognize = case image of
                              Left reason -> ioError (userError reason)
                              Right snapshot -> predictOcr snapshot ocr
                        queued <- queueComparison runtime production recognize
                        if queued then do
                          when production $ ocrState $=! OcrPending
                          atomically $ writeTChan collect "[检测] 已提交刻字与预设文字比对\n"
                        else atomically $ writeTChan collect "[忙] 上一次检测尚未完成，请等待结果后重新触发\n"
                  triggered <- (== "ok") <$> modbusTrigger
                  rising <- triggerRising runtime triggered
                  when (rising || isEvent b21') $ submitInspection True

                  let FontSet{..} = fontSet
                  pushFont msyhlFont
                  result <- collapsingHeader "刻字文字比对"
                  col $=! result
                  popFont

                  when result $ do
                    -- print $ "x " ++ show x ++ " y " ++ show y ++ " w " ++ show w ++ " h " ++ show h
                    withID ("serial number":: Text) $ do
                      dragFloat "ratio" ratio 0.1 1.0 4.0
                      sameLine
                      showHelp msyhlFont "调整刻字预览窗口的放大倍数，当图像比较小的时候，调整图像大小，便于人工观察"
                      dragFloat "scale" scale 0.1 1.0 10.0
                      sameLine
                      showHelp msyhlFont "刻字图像输入OCR识别程序前的放大倍数，如果刻字间距太密导致识别率低，可以调整这个放大倍数"
                      dragFloat2 "offSet" rx 1.0 0.0 500.0
                      sameLine
                      showHelp msyhlFont "刻字预览窗口的位置偏移，当刻字坐标太靠近屏幕下边沿或者右边沿，预览窗口显示不全的时候，配合预览窗口放大倍数进行调整"

                    bracket_ (pushFont msyhlFont) popFont $ do
                      changedPreset <- inputText "预设文字" (comparisonPreset runtime) 4096
                      sameLine
                      showHelp msyhlFont "识别区域的完整文字必须与预设一致。保留中文、英文大小写、数字及标点；忽略空白，中英文冒号等价。不进行顺号检查。保存参数可记忆当前文字。"
                      when changedPreset $ do
                        syncComparisonSettings runtime liveProfile
                        ocrState $=! OcrUnknown
                      clicked <- button "评估"
                      sameLine
                      showHelp msyhlFont "比对选中区域的刻字与预设文字并显示结果；评估不写PLC，不改变生产计数。点击检测一次或PLC触发进行生产检测。"
                      when clicked $ submitInspection False
                      sameLine
                      productionClicked <- button "检测一次"
                      when productionClicked $ submitInspection True

                    when (sg == (Running 1)) $ do
                      setNextWindowPos pos ImGuiCond_Always Nothing
                      setNextWindowSize size ImGuiCond_Always
                    bracket_ (begin3 "刻字预览") end $ do

                      let src' = matFlip src FlipVertically
                      glBindTexture GL_TEXTURE_2D texId
                      withMatData src' $ (\step ptr-> do
                        let [h,w] = miShape $ matInfo src'
                        glTexImage2D GL_TEXTURE_2D 0
                          GL_RGB 
                          w h
                          0 GL_RGB GL_UNSIGNED_BYTE
                          (castPtr ptr)
                        glGenerateMipmap GL_TEXTURE_2D)

                      ImVec2 w h <- get size
                      ImVec2 px py <- get pos
                      let [h2,w2] = miShape $ matInfo src
                          [h3,w3] = [fromIntegral h2, fromIntegral w2]

                      Foreign.with (ImVec2 (w*b10) (h*b10)) \sizePtr ->
                        Foreign.with (ImVec2 ((px+b40)/w3) ((py+b41)/h3)) \uv0Ptr ->
                          Foreign.with (ImVec2 ((px + b40 + w)/w3) ((py + b41 + h)/h3)) \uv1Ptr ->
                            Foreign.with (ImVec4 1 1 1 1) \tintColPtr ->
                              Foreign.with (ImVec4 1 1 1 0.5) \bgColPtr ->
                                image (intPtrToPtr $ fromIntegral texId) sizePtr uv0Ptr uv1Ptr tintColPtr bgColPtr

                      a <- getWindowPos
                      pos $=! a
                      b <- getWindowSize
                      size $=! b

                    return ()

                  return src
                  ), oe')
  where
    trackInt = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (1, False)


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


showHelp font msg = do
  pushFont font
  helpMarker msg
  popFont
