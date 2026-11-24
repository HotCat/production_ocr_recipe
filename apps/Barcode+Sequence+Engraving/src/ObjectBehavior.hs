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
import qualified ProductionDebug as PD
import BankRecipes (bankRecipes, bankRecipe)

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
import           BarcodeGuard
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

combineAll :: RandomGen g => g -> BarcodeRuntime -> SF GameInput ((Env -> GLuint -> IORef CtrlRef -> FontSet Font -> IO ()), RegulSF, RegulSF, (Env -> IO ()), RegulSF, RegulSF, ChainSF, ChainSF, ChainSF2, RegulSF, ChainSF3)
combineAll g barcodeRuntime = proc oi -> do
  a <- bootStrap -< oi
  b <- showConsole -< oi
  c <- cameraParams -< oi
  d <- sentinel -< oi
  e <- selectConfig -< oi
  f <- saveConfig -< oi
  g <- barcodeOCR barcodeRuntime -< oi
  h <- opencvCanny -< oi
  i <- serialNumOCR -< oi
  j <- overLord g barcodeRuntime -< oi
  k <- motionSense -< oi
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


selectRange :: SF GameInput (IORef CtrlRef -> FontSet Font -> IO ())
selectRange = myAux Init
  where
    myAux sg = switch (selectRange' sg) myAux

selectRange' :: Stage -> SF GameInput (IORef CtrlRef -> FontSet Font -> IO (), Event Stage)
selectRange' sg = proc oi -> do
  let (Just (PinItem1 b10)) = Map.lookup "production-ok-hold" (giCtrl oi)
      (Just (PinItem1 b11)) = Map.lookup "serial-number-range-select-active" (giCtrl oi)
      (Just (CompItem1 seq)) = Map.lookup "serial-number-sequence-marker" (giCtrl oi)

  fire <- after 3 () -< ()
  evt <- edge -< b10
  confirm <- edge -< (not b11)
  clsR <- iPre NoEvent >>> once -< gate (Event ()) (sg == Running 2)

  let ae = gate (Event (Running 1)) (sg == Init && isEvent evt)
      be = gate (Event Init) (sg == (Running 1) && not b10)
      ce = gate (Event (Running 2)) (sg == (Running 1) && isEvent fire)
      de = gate (Event Init) (sg == (Running 2) && isEvent confirm)
      oe = mergeEvents [ae,be,ce,de]

  oe' <- iPre noEvent -< oe
  returnA -< (\ctrlMaps fontSet -> do
                 ctrlMaps' <- get ctrlMaps
                 let (Just (PinHub1 item)) = Map.lookup "serial-number-range-select-active" ctrlMaps'
                     (Just (CombHub1 ok)) = Map.lookup "production-ok-count" ctrlMaps'
                     (Just (CompHub1 refSeq)) = Map.lookup "serial-number-sequence-marker" ctrlMaps'
                     (Just (TrigHub1 tr)) = Map.lookup "barcode-ocr-trigger" ctrlMaps'
                     (Just (ChanHub2 collect_batch)) = Map.lookup "barcode-ocr-collect-batch" ctrlMaps'

                 if(isEvent clsR) then refSeq $=! Nothing else return ()

                 when (sg == (Running 2)) $ do
                   tr' <- get tr
                   (refSer,ser,len)  <- case tr' of
                     Nothing -> do
                       a <- newIORef ""
                       return (a,"",0)
                     (Just ser) -> do
                       a <- newIORef (T.pack ser)
                       return (a,ser,(length ser))

                   [start,end] <- inputText2 "选择顺号区域" refSer len
                   a <- Raw.isItemActive
                   let b = if (start < end) then (slice start end ser) else (slice end start ser)
                   print $ "isItemActive " ++ show a
                   print $ "inputText2 " ++ show start ++ " " ++ show end ++ " " ++ b

                   let baseNum :: String
                       baseNum = printf ("%0" ++ show ((abs (start - end )) + 1) ++ "d") ser

                   when (b11 && ((length b <= 3) || isNothing ((R.readMaybe b) :: (Maybe Integer)))) $ do
                     refSeq $=! Nothing

                   when (b11 && (length b > 3) && isJust ((R.readMaybe b) :: (Maybe Integer))) $ do
                     refSeq $=! Just (Compound ser (read b) start end)

                   item $=! a

                   when (isEvent confirm) $ do
                     ok $=! 0
                     atomically $ writeTChan collect_batch $ "reset " ++ show seq
                     return ()
                   
                 return ()
                 , oe')


slice :: Int -> Int -> [a] -> [a]
slice from to xs = take (to - from) (drop from xs)


debounce :: SF GameInput (Event String)
debounce = arr completed >>> inspectionCompletions
  where
    completed oi = case Map.lookup "serial-number-plc-modbus-trigger" (giCtrl oi) of
      Just (TrigItem1 result) -> result
      _ -> Nothing


bounceR :: SF GameInput (IORef CtrlRef -> IO ())
bounceR = myAux (Init, OcrUnknown)
  where
    myAux sg = switch (bounceR' sg) myAux

bounceR' :: (Stage,OcrState) -> SF GameInput ((IORef CtrlRef -> IO ()), Event (Stage,OcrState))
bounceR' (sg, ocr) = proc oi -> do
  let (Just (OcrItem1 os)) = Map.lookup "batchocr-state-variable" (giCtrl oi)
  fire <- after 0.8 () -< ()
  r <- repeatedly 0.2 () -< ()
  up <- accumHold False -< r `tag` (\a-> not a)

  r1 <- once -< gate (Event ()) (sg == Running 1)
  r2 <- once -< gate (Event ()) (sg == Running 2)

  let ae = gate (Event ((Running 1), OcrPass)) (sg == Init && os == OcrPass)
      be = gate (Event ((Running 2), OcrFail)) (sg == Init && os == OcrFail)
      ce = gate (Event ((Running 2), OcrFail)) (sg == (Running 1) && os == OcrFail)
      de = gate (Event ((Running 1), OcrPass)) (sg == (Running 2) && os == OcrPass)
      ee = gate (Event (Init, OcrUnknown)) (sg == (Running 1) && isEvent fire)
      fe = gate (Event (Init, OcrUnknown)) (sg == (Running 2) && isEvent fire)
      oe = mergeEvents [ae,be,ce,de,ee,fe]

  oe' <- iPre noEvent -< oe
  returnA -< (\ctrlMaps-> do
                 ctrlMaps' <- get ctrlMaps
                 let (Just (OcrHub1 ocrState)) = Map.lookup "batchocr-state-variable" ctrlMaps'

                 -- case (trace ("sg = " ++ show sg) sg) of
                 --   (Running 1) -> do
                 --     print $ "running 1 os " ++ show os
                 --   (Running 2) -> do
                 --     print $ "running 2 os " ++ show os
                 --   _ -> return ()

                 when ((isEvent fire) || (isEvent r1) || (isEvent r2)) $ do
                   ocrState $=! OcrUnknown

                 (ImVec2 x y) <- getWindowPos
                 win <- getWindowDrawList
                 let b10 = if up then ocr else OcrUnknown
                 Foreign.with (ImVec2 x (y+150)) \pMin ->
                      Foreign.with (ImVec2 (x+100) (y+250)) \pMax ->
                        DrawList.addRectFilled
                          win
                          pMin pMax
                          case b10 of
                            OcrPass -> (Raw.imCol32 0 255 0 0xFF)
                            OcrFail -> (Raw.imCol32 255 0 0 0xFF)
                            OcrPending -> (Raw.imCol32 255 255 0 0xFF)
                            OcrUnknown -> (Raw.imCol32 0 0 0 0xFF)
                          0 ImDrawFlags_None
                 return ()
                 , oe')


winPeriod :: SF GameInput (IORef CtrlRef -> Either e (Mat ('S '[ 'D, 'D]) ('S 3) ('S Word8)) -> PPOCR -> IO ())
winPeriod = myAux Init
  where
    myAux sg = switch (winPeriod' sg) myAux

winPeriod' :: Stage -> SF GameInput (IORef CtrlRef -> Either e (Mat ('S '[ 'D, 'D]) ('S 3) ('S Word8)) -> PPOCR -> IO (), Event Stage)
winPeriod' sg = proc oi -> do
  let (Just (TrigItem1 b10)) = Map.lookup "serial-number-ocr-trigger" (giCtrl oi)
      (Just (OcrItem1 os)) = Map.lookup "batchocr-state-variable" (giCtrl oi)

  fire <- after 0.2 (Running 2) -< ()
  dur <- after 0.5 (Running 3) -< ()
  approach <- edgeJust -< b10
  let ae = gate (Event (Running 1)) (sg == Init && isEvent approach)
      -- be = gate fire (sg == (Running 1))
      be = gate (Event (Running 2)) (sg == (Running 1))
      ce = gate (Event Init) (sg == (Running 2) && ((os == OcrPass) || (os == OcrFail)))
      de = gate dur (sg == (Running 2))
      ee = gate (Event Init) (sg == (Running 3))
      oe = mergeEvents [ae,be,ce,de,ee]

  oe' <- iPre noEvent -< oe
  returnA -< (\ctrlMaps roi ocr -> do
                 ctrlMaps' <- get ctrlMaps
                 let (Just (TrigHub1 chkSer)) = Map.lookup "serial-number-ocr-trigger" ctrlMaps'
                     (Just (OcrHub1 ocrState)) = Map.lookup "batchocr-state-variable" ctrlMaps'
                     (Just (ChanHub2 collect_batch)) = Map.lookup "serial-number-ocr-collect-batch" ctrlMaps'
                     (Just (CombHub1 bankSelection)) = Map.lookup "serial-number-bank" ctrlMaps'

                 -- print $ "sg = " ++ show sg ++ " " ++ show b10
                 case sg of
                   Init -> do
                     return ()

                   (Running 1) -> do
                     return ()

                   (Running 2) -> do
                     case b10 of
                       (Just curSerial) -> do
                         case roi of
                           (Left _) -> do
                             print "match serial number fail!"
                             ocrState $=! OcrFail
                             chkSer $=! Nothing
                             atomically $ writeTChan collect_batch $ "serial number ng " ++ curSerial
                             return ()

                           (Right r) -> do
                             bank <- get bankSelection
                             PL.rememberObservation "engraving.bank" (show bank)
                             let serialLength = snd (bankRecipe bank)
                             result <- try (predictOcr r ocr) :: IO (Either IOException String)
                             case result of
                               Left failure -> do
                                 ocrState $=! OcrFail
                                 chkSer $=! Nothing
                                 atomically $ writeTChan collect_batch $
                                   "serial number ng " ++ curSerial ++ "; PaddleOCR: " ++ displayException failure
                               Right serNum -> do
                                 PL.rememberObservation "engraving.raw" serNum
                                 when ((T.unpack (T.takeEnd serialLength (T.filter (\n-> (isNumber n) || (isAlpha n)) $ T.pack serNum))) == curSerial) $ do
                                   ocrState $=! OcrPass
                                   chkSer $=! Nothing
                                   atomically $ writeTChan collect_batch $ "serial number ok " ++ curSerial

                       Nothing -> return ()

                   (Running 3) -> do
                     if (os == OcrPass) then return () else ocrState $=! OcrFail
                     chkSer $=! Nothing
                     return ()

                   _ -> do
                     return ()
                 , oe')


scheduler :: SF GameInput (IORef CtrlRef -> IO () -> IO () -> IO ())
scheduler = myAux Init
  where
    myAux sg = switch (scheduler' sg) myAux

scheduler' :: Stage -> SF GameInput (IORef CtrlRef -> IO () -> IO () -> IO (), Event Stage)
scheduler' sg = proc oi -> do
  let (Just (OcrItem1 os)) = Map.lookup "batchocr-state-variable" (giCtrl oi)
      (Just (TrigItem1 b10)) = Map.lookup "serial-number-ocr-trigger" (giCtrl oi)

  serEvt <- edgeJust -< b10

  let ae = gate (Event (Running 1)) (sg == Init)
      be = gate (Event (Running 2)) (sg == (Running 1) && isEvent serEvt)
      ce = gate (Event (Running 1)) (sg == (Running 2) && (os == OcrPass || os == OcrFail))
      oe = mergeEvents [ae,be,ce]

  oe' <- iPre noEvent -< oe
  returnA -< (\ctrlMaps barM serM -> do
                 ctrlMaps' <- get ctrlMaps
                 case sg of
                   (Running 1) -> do
                     barM

                   (Running 2) -> do
                     serM

                   _ -> return ()

                 return ()
                 , oe')


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
  returnA -< ((\env ctrlMaps fontSet->do
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
                        let r1' = (maybe "" ("[serial]: " ++) r1)
                            r2' = (maybe "" ("[barcode]: " ++) r2)
                            r3' = (maybe "" (\a-> timeStamp ++ "[serial]: " ++ a) r3)
                            r4' = (maybe "" (\a-> timeStamp ++ "[barcode]: " ++ a) r4)
                        showAppLog (r1' ++ r2' ++ r3' ++ r4')

              ), oe')


overLord :: RandomGen g => g -> BarcodeRuntime -> SF GameInput RegulSF
overLord g runtime = myAux Init
  where
    myAux sg = switch (overLord' g runtime sg) myAux

overLord' :: RandomGen g => g -> BarcodeRuntime -> Stage -> SF GameInput (RegulSF, Event Stage)
overLord' g runtime sg = proc oi -> do
  let (Just (OcrItem1 os)) = Map.lookup "batchocr-state-variable" (giCtrl oi)
      (Just (TrigItem1 b10)) = Map.lookup "serial-number-ocr-trigger" (giCtrl oi)
      (Just (PinItem1 b11)) = Map.lookup "opencv-canny-enable" (giCtrl oi)
      (Just (CompItem1 seq)) = Map.lookup "serial-number-sequence-marker" (giCtrl oi)

  serEvt <- edgeJust -< b10

  let ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]

  approach <- debounce -< oi
  currentInspection <- hold "" -< approach
  let inspection = R.readMaybe currentInspection :: Maybe BarcodeResult
      curSerial = maybe "" barcodeDecoded inspection
  oe' <- iPre noEvent -< oe
  okcls <- holdAfter 3.0 "production-ok-hold" >>> edge -< oi

  selM <- selectRange -< oi
  blinkM <- bounceR -< oi
  schedM <- scheduler -< oi

  returnA -< ((\env ctrlMaps fontSet->do
                  ctrlMaps' <- get ctrlMaps
                  let (Just (PinHub1 trigger)) = Map.lookup "trigger-batchocr-operation" ctrlMaps'
                      (Just (PinHub1 restore)) = Map.lookup "trigger-parameters-restore" ctrlMaps'
                      (Just (OcrHub1 ocrState)) = Map.lookup "batchocr-state-variable" ctrlMaps'
                      (Just (CombHub1 ok)) = Map.lookup "production-ok-count" ctrlMaps'
                      (Just (CombHub1 ng)) = Map.lookup "production-ng-count" ctrlMaps'
                      (Just (CompHub1 refSeq)) = Map.lookup "serial-number-sequence-marker" ctrlMaps'
                      (Just (ChanHub2 collect_batch)) = Map.lookup "barcode-ocr-collect-batch" ctrlMaps'
                      (Just (TrigHub1 chkSer)) = Map.lookup "serial-number-ocr-trigger" ctrlMaps'
                      (Just (PinHub1 guardSetting)) = Map.lookup "barcode-printed-text-guard" ctrlMaps'
                      (Just (CombHub1 bankSetting)) = Map.lookup "serial-number-bank" ctrlMaps'

                  let FontSet{..} = fontSet
                  pushFont msyhlFont

                  size <- newIORef $ ImVec2 281 316
                  setNextWindowSize size ImGuiCond_Once
                  bracket_ (begin3 "识别结果") end $ do

                    let logVerdict passed reason = do
                          enabled <- get guardSetting
                          selectedBank <- get bankSetting
                          observedBank <- PL.readObservation "engraving.bank"
                          let bank = maybe selectedBank id (R.readMaybe observedBank)
                          raw <- PL.readObservation "engraving.raw"
                          let (bankName, serialLength) = bankRecipe bank
                          PL.recordProduction $ (PL.productionEvent "Barcode+Sequence+Engraving" passed)
                            { PL.eventBarcode = curSerial
                            , PL.eventSerial = T.unpack (T.takeEnd serialLength (T.filter (\n -> isNumber n || isAlpha n) (T.pack raw)))
                            , PL.eventDetected = raw
                            , PL.eventGuard = Just enabled, PL.eventReverse = Just b11
                            , PL.eventBank = bankName, PL.eventBankIndex = Just bank
                            , PL.eventBankSerialLength = Just serialLength, PL.eventReason = reason }
                        reject message = do
                          logVerdict False message
                          ocrState $=! OcrFail
                          modifyIORef' ng (+1)
                          modbusNg
                          setBarcodeProductionBusy runtime False
                          atomically $ writeTChan collect_batch ("NG " ++ message ++ " 条码=" ++ show curSerial ++ "\n")
                        barM = do
                          when (isEvent approach) $ do
                            PL.rememberObservation "engraving.raw" ""
                            PL.rememberObservation "engraving.bank" ""
                            enabled <- get guardSetting
                            let expected = fmap (\marker ->
                                  (printf ("%0" ++ show (abs (serStart marker - serEnd marker)) ++ "d") (serBody marker),
                                   serStart marker, serEnd marker)) seq
                                decision = maybe (ProductionRejected "无效的条码检测结果")
                                                 (decideProduction enabled expected) inspection
                            case decision of
                              ProductionRejected reason -> reject reason
                              SequenceUnconfigured -> PD.finishDebugTrigger >> setBarcodeProductionBusy runtime False
                              SequenceMismatched -> reject "顺号不连续"
                              SequenceMatched -> do
                                -- Continue with the existing engraving comparison
                                -- only after both barcode guards have passed.
                                ocrState $=! OcrPending
                                chkSer $=! Just curSerial

                        serM = when (os == OcrPass || os == OcrFail) $ PD.withDebugVerdict $ do
                          case os of
                            OcrPass -> do
                              enabled <- get guardSetting
                              if maybe False (guardAllowsResult enabled) inspection then do
                                case seq of
                                  Nothing -> when PD.debugMode $ reject "检测期间起始号已被清除"
                                  Just marker -> do
                                    logVerdict True "条码及刻字检测通过"
                                    refSeq $=! Just (marker {serBody = serBody marker + (if b11 then -1 else 1)})
                                    modifyIORef' ok (+1)
                                    modbusOk
                                setBarcodeProductionBusy runtime False
                              else reject "印字校验设置已改变，请重新检测"
                            
                            OcrFail -> do
                              logVerdict False "刻字与条码不一致/刻字识别失败"
                              modifyIORef' ng (+1)
                              modbusNg
                              setBarcodeProductionBusy runtime False

                            _ -> return ()

                    schedM ctrlMaps barM serM

                    text $ T.pack $ case seq of
                      Nothing -> "未设置起始号"
                      (Just seq) -> show seq
                    text $ T.pack $ curSerial
                    case seq of
                      Nothing -> return ()
                      (Just seq) -> do
                        let baseNum = printf ("%0" ++ show (abs (serStart seq - serEnd seq)) ++ "d") (serBody seq)
                        text $ T.pack baseNum

                    selM ctrlMaps fontSet
                    blinkM ctrlMaps

                  popFont


              ), oe')
  where
    (g', g'') = split g

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
                dragFloat' env b14' "Exposure" exposure 500.0 1000.0 50000.0
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
    withFile ("/dev/shm/sequence2/config" ++ show (val+1) ++ ".scm") ReadMode $ \handle -> do
      xs <- hGetContents handle
      result <- LSC.evalString env xs
      print result

  when restore $ do
    withFile ("/dev/shm/sequence2/config" ++ show (val+1) ++ ".scm") ReadMode $ \handle -> do
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
      (Just (PinItem1 barcodeGuard)) = Map.lookup "barcode-printed-text-guard" (giCtrl oi)
      (Just (CombItem1 serialBank)) = Map.lookup "serial-number-bank" (giCtrl oi)
      (Just (DragItem1 b18)) = Map.lookup "serial-number-scale-factor" (giCtrl oi)
      (Just (DragItem1 b19)) = Map.lookup "serial-number-preview-zoom" (giCtrl oi)
      (Just (DragItem1 b23)) = Map.lookup "barcode-scale-factor" (giCtrl oi)
      (Just (DragItem1 b24)) = Map.lookup "barcode-preview-zoom" (giCtrl oi)
      (Just (DragItem1 b25)) = Map.lookup "motion-sense-lag" (giCtrl oi)

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
                  clicked <- button "保存参数"
                  when PD.debugMode $ do
                    sameLine
                    debugClicked <- button "触发modbus"
                    when debugClicked $ do
                      debugControls <- get ctrlMaps
                      let (Just (ChanHub2 debugMessages)) = Map.lookup "barcode-ocr-collect-batch" debugControls
                      let (Just (CompHub1 markerRef)) = Map.lookup "serial-number-sequence-marker" debugControls
                      marker <- get markerRef
                      if isJust marker then do
                        accepted <- PD.requestDebugTrigger
                        atomically $ writeTChan debugMessages $
                          if accepted then "[调试] 已提交模拟Modbus触发，执行完整生产检测\n"
                                      else "[调试] 上一次检测尚未结束，请等待结果后重试\n"
                      else atomically $ writeTChan debugMessages "[调试] 请先设置起始号及顺号区域，再触发检测\n"
                  sameLine
                  showHelp msyhlFont "保存当前配置的所有参数，如果临时调整了参数，想进行快速还原，可以按x键"
                  when clicked $ do
                    withFile ("/dev/shm/sequence2/config" ++ show (val+1) ++ ".scm") WriteMode $ \handle -> do
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
                      
                      hPrintf handle configTemplate3 ("opencv-canny-enable"::String) (if b17 then "#t"::String else "#f"::String)
                      hPrintf handle configTemplate3 ("barcode-printed-text-guard"::String) (if barcodeGuard then "#t"::String else "#f"::String)

                      hPrintf handle configTemplate2 ("opengl-camera-parameters"::String) (b20::Float) (b21::Float) (b22::Float)
                      hPrintf handle configTemplate3 ("camera-param-reverse-x"::String) (if rx then "#t"::String else "#f"::String)
                      hPrintf handle configTemplate3 ("camera-param-reverse-y"::String) (if ry then "#t"::String else "#f"::String)

                      hPrintf handle configTemplate4 ("serial-number-region-select"::String) (b40::Float) (b41::Float) (b42::Float) (b43::Float)
                      hPrintf handle configTemplate4 ("barcode-region-select"::String) (b44::Float) (b45::Float) (b46::Float) (b47::Float)
                      hPrintf handle configTemplate4 ("motion-region-select"::String) (b50::Float) (b51::Float) (b52::Float) (b53::Float)

                      hPrintf handle configTemplate5 ("serial-number-ocr-start"::String) (b60::Float) (b61::Float)
                      hPrintf handle configTemplate5 ("barcode-ocr-start"::String) (b62::Float) (b63::Float)

                      hPrintf handle configTemplate6 ("serial-number-bank"::String) (serialBank::Int)
                      hPrintf handle configTemplate6 ("production-ok-count"::String) (b70::Int)
                      hPrintf handle configTemplate6 ("production-ng-count"::String) (b71::Int)
                      hPrintf handle ")"
                  popFont
                  ), oe')

  where
    trackInt = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (1, False)


barcodeOCR :: BarcodeRuntime -> SF GameInput ChainSF
barcodeOCR runtime = myAux Init
  where
    myAux sg = dSwitch (barcodeOCR' runtime sg) myAux

barcodeOCR' :: BarcodeRuntime -> Stage -> SF GameInput (ChainSF, Event Stage)
barcodeOCR' runtime sg = proc oi -> do
  let (Just (RectItem4 (x,y,w,h))) = Map.lookup "barcode-region-select" (giCtrl oi)
      (Just (PinItem1 b20)) = Map.lookup "barcode-collapse-enabled" (giCtrl oi)
      (Just (PinItem1 b21)) = Map.lookup "trigger-batchocr-operation" (giCtrl oi)
      (Just (PinItem1 b22)) = Map.lookup "trigger-parameters-restore" (giCtrl oi)
      (Just (CombItem1 b30)) = Map.lookup "all-configurations-index" (giCtrl oi)
      (Just (DragItem1 b10)) = Map.lookup "barcode-preview-zoom" (giCtrl oi)
      (Just (DragItem1 b11)) = Map.lookup "barcode-scale-factor" (giCtrl oi)
      (Just (DragItem2 (b40,b41))) = Map.lookup "barcode-ocr-start" (giCtrl oi)

      ae = gate (Event (Running 1)) (sg == Init)
      be = gate (Event (Running 2)) (sg == (Running 1) && b20 == True)
      ce = gate (Event (Running 1)) (sg == (Running 2) && b20 == False)
      oe = mergeEvents [ae,be,ce]

  oe' <- iPre noEvent -< oe
  (val, changed) <- trackInt -< b30
  b21' <- edge -< b21
  restore <- edge -< b22

  isGen <- iPre NoEvent >>> once -< gate (Event Bool) (sg == Init)

  returnA -< ((\env ctrlMaps fontSet src -> do
                  ctrlMaps' <- get ctrlMaps
                  let (Just (RectHub4 win)) = Map.lookup "barcode-region-select" ctrlMaps'
                      (Just (PinHub1 col)) = Map.lookup "barcode-collapse-enabled" ctrlMaps'
                      (Just (PinHub1 guardSetting)) = Map.lookup "barcode-printed-text-guard" ctrlMaps'
                      (Just (TexIdHub1 texId)) = Map.lookup "barcode-ocr-region" ctrlMaps'
                      (Just (DragHub1 ratio)) = Map.lookup "barcode-preview-zoom" ctrlMaps'
                      (Just (DragHub1 scale)) = Map.lookup "barcode-scale-factor" ctrlMaps'
                      (Just (ChanHub1 submit)) = Map.lookup "barcode-ocr-submit" ctrlMaps'
                      (Just (ChanHub2 collect)) = Map.lookup "barcode-ocr-collect" ctrlMaps'
                      (Just (ChanHub1 submit_batch)) = Map.lookup "barcode-ocr-submit-batch" ctrlMaps'
                      (Just (ChanHub2 collect_batch)) = Map.lookup "barcode-ocr-collect-batch" ctrlMaps'
                      (Just (DragHub2 ry)) = Map.lookup "barcode-ocr-start" ctrlMaps'
                      (Just (TrigHub1 tr)) = Map.lookup "barcode-ocr-trigger" ctrlMaps'
                      (Just (TrigHub1 plc)) = Map.lookup "serial-number-plc-modbus-trigger" ctrlMaps'
                      (Just (PinHub1 enable)) = Map.lookup "opencv-canny-enable" ctrlMaps'

                  guardEnabled <- get guardSetting
                  previousGuard <- getBarcodeGuardEnabled
                  when (guardEnabled /= previousGuard) $ do
                    setBarcodeGuardEnabled guardEnabled
                    resetBarcodeInspection runtime
                    atomically $ writeTChan collect $
                      if guardEnabled then "[设置] 印字校验开启：印字必须包含完整条码内容\n"
                                      else "[设置] 印字校验关闭：仅检查条码顺号与刻字\n"

                  -- Publish completed inspections once to the production path. OCR never blocks capture or UI rendering.
                  plc $=! Nothing
                  completed <- pollBarcodeInspection runtime
                  case completed of
                    Nothing -> return ()
                    Just inspection -> do
                      if barcodeGuardEnabled inspection /= guardEnabled then do
                        PD.finishDebugTrigger
                        atomically $ writeTChan collect_batch "[结果已丢弃] 印字校验设置已改变，重新检测当前标签\n"
                      else do
                        atomically $ writeTChan collect_batch (formatBarcodeResult inspection)
                        setBarcodeProductionBusy runtime True
                        plc $=! Just (show inspection)

                  when (isEvent isGen) $ do
                    print "I am in init2"
                    forkIO $ procBarcode submit collect
                    forkIO $ procBarcode submit_batch collect_batch
                    return ()

                  (pos,size) <- get win

                  when changed $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always

                  when (isEvent restore) $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always

                  let subRect = toRect $ HRect (V2 ((round x)+(round b40)) ((round y)+(round b41))) (V2 (round (w/b10)) (round (h/b10)))
                      r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                  triggered <- modbusTriggered
                  when PD.debugMode $ queueDebugBarcodeInspection runtime guardEnabled triggered $
                    either (const (Left "条码识别区域无效，请重新选择")) Right r
                  case r of
                    Left _ -> do
                      tr $=! Nothing
                      unless PD.debugMode $ queueBarcodeInspection runtime guardEnabled False "ng" src
                    Right labelImage -> do
                      -- Decode only for the live range-selection preview. The
                      -- asynchronous inspection is the production authority.
                      decoded <- decodeBarcode labelImage
                      tr $=! (if decoded == "ng" then Nothing else Just decoded)
                      unless PD.debugMode $ queueBarcodeInspection runtime guardEnabled triggered decoded labelImage

                  when (isEvent b21') $ do
                      let subRect = toRect $ HRect (V2 ((round x)+(round b40)) ((round y)+(round b41))) (V2 (round (w/b10)) (round (h/b10)))
                          r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                      case r of
                        (Left _) -> return ()
                        (Right r) -> atomically $ writeTChan submit_batch r
                      return ()


                  let FontSet{..} = fontSet
                  pushFont msyhlFont
                  result <- collapsingHeader "条码识别"
                  col $=! result
                  popFont

                  when result $ do
                    withID ("barcode":: Text) $ do
                      dragFloat "ratio" ratio 0.1 1.0 4.0
                      sameLine
                      showHelp msyhlFont "调整条码预览窗口的放大倍数，当图像比较小的时候，调整图像大小，便于人工观察"
                      dragFloat "scale" scale 0.1 1.0 10.0
                      sameLine
                      showHelp msyhlFont "条码图像输入OCR识别程序前的放大倍数，默认为1就行，数值太大，OCR识别速度变慢"
                      dragFloat2 "offSet" ry 1.0 0.0 500.0
                      sameLine
                      showHelp msyhlFont "条码预览窗口的位置偏移，当条码坐标太靠近屏幕下边沿或者右边沿，预览窗口显示不全的时候，配合预览窗口放大倍数进行调整"

                    bracket_ (pushFont msyhlFont) popFont $ do
                      changedGuard <- checkbox "校验印字与条码一致" guardSetting
                      sameLine
                      showHelp msyhlFont "开启后使用PaddleOCR识别同一区域的印字，只要印字中包含完整条码内容即通过（忽略空白，保留大小写和标点）。允许周围有额外文字；未找到条码内容、无印字或OCR失败均判NG，顺号不前进。"
                      when changedGuard $ do
                        selected <- get guardSetting
                        setBarcodeGuardEnabled selected
                        resetBarcodeInspection runtime
                        atomically $ writeTChan collect $
                          if selected then "[设置] 印字校验开启：印字必须包含完整条码内容\n"
                                      else "[设置] 印字校验关闭：仅检查条码顺号与刻字\n"

                    checkbox "Reverse" enable
                    clicked <- withID ("barcode":: Text) $ button "评估"
                    sameLine
                    showHelp msyhlFont "识别选中区域中的条码，将结果显示在日志窗口，用于条码的OCR识别区域的标定"
                    when clicked $ do
                      let subRect = toRect $ HRect (V2 ((round x)+(round b40)) ((round y)+(round b41))) (V2 (round (w/b10)) (round (h/b10)))
                          r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                      case r of
                        (Left _) -> return ()
                        (Right r) -> atomically $ writeTChan submit r
                      return ()

                    when (sg == (Running 1)) $ do
                      setNextWindowPos pos ImGuiCond_Always Nothing
                      setNextWindowSize size ImGuiCond_Always
                    bracket_ (begin3 "条码预览") end $ do

                      let src' = matFlip src FlipVertically
                      glBindTexture GL_TEXTURE_2D texId
                      withMatData src' $ (\step ptr-> do
                        let [h,w] = miShape $ matInfo src'
                        glTexImage2D GL_TEXTURE_2D 0
                          GL_RGB 
                          w h
                          0 GL_RGB GL_UNSIGNED_BYTE
                          (castPtr ptr))

                      ImVec2 w h <- get size
                      ImVec2 px py <- get pos
                      let [h2,w2] = miShape $ matInfo src
                          [h3,w3] = [fromIntegral h2, fromIntegral w2]

                      Foreign.with (ImVec2 (w*b10) (h*b10)) \sizePtr ->
                        Foreign.with (ImVec2 ((px+b40)/w3) ((py+b41)/h3)) \uv0Ptr ->
                          Foreign.with (ImVec2 ((px +b40 + w)/w3) ((py + b41 + h)/h3)) \uv1Ptr ->
                            Foreign.with (ImVec4 1 1 1 1) \tintColPtr ->
                              Foreign.with (ImVec4 1 1 1 0.5) \bgColPtr ->
                                image (intPtrToPtr $ fromIntegral texId) sizePtr uv0Ptr uv1Ptr tintColPtr bgColPtr

                      a <- getWindowPos
                      pos $=! a
                      b <- getWindowSize
                      size $=! b

                    return ()

                  let subRect = toRect $ HRect (V2 ((round x)+(round b40)) ((round y)+(round b41))) (V2 (round (w/b10)) (round (h/b10)))
                      r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                  case r of
                    -- Keep the camera frame visible while an invalid crop is adjusted.
                    (Left _) -> return src
                    (Right r) -> return r
                  -- return src
                  ), oe')

  where
    trackInt = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (1, False)



motionSense :: SF GameInput ChainSF3
motionSense = myAux Init
  where
    myAux sg = dSwitch (motionSense' sg) myAux

motionSense' :: Stage -> SF GameInput (ChainSF3, Event Stage)
motionSense' sg = proc oi -> do
  let (Just (RectItem4 (x,y,w,h))) = Map.lookup "motion-region-select" (giCtrl oi)
      (Just (PinItem1 b20)) = Map.lookup "motion-collapse-enabled" (giCtrl oi)
      (Just (PinItem1 b21)) = Map.lookup "trigger-batchocr-operation" (giCtrl oi)
      (Just (PinItem1 b22)) = Map.lookup "trigger-parameters-restore" (giCtrl oi)
      (Just (CombItem1 b30)) = Map.lookup "all-configurations-index" (giCtrl oi)
      (Just (DragItem1 b10)) = Map.lookup "motion-sense-lag" (giCtrl oi)
      (Just (DragItem1 b11)) = Map.lookup "barcode-scale-factor" (giCtrl oi)

      ae = gate (Event (Running 1)) (sg == Init)
      be = gate (Event (Running 2)) (sg == (Running 1) && b20 == True)
      ce = gate (Event (Running 1)) (sg == (Running 2) && b20 == False)
      oe = mergeEvents [ae,be,ce]

  oe' <- iPre noEvent -< oe
  (val, changed) <- trackInt -< b30
  b21' <- edge -< b21
  restore <- edge -< b22

  isGen <- iPre NoEvent >>> once -< gate (Event Bool) (sg == Init)

  returnA -< ((\env ctrlMaps fontSet backSub src -> do
                  ctrlMaps' <- get ctrlMaps
                  let (Just (RectHub4 win)) = Map.lookup "motion-region-select" ctrlMaps'
                      (Just (PinHub1 col)) = Map.lookup "motion-collapse-enabled" ctrlMaps'
                      (Just (TexIdHub1 texId)) = Map.lookup "motion-sense-region" ctrlMaps'
                      (Just (DragHub1 lag)) = Map.lookup "motion-sense-lag" ctrlMaps'
                      (Just (DragHub1 scale)) = Map.lookup "barcode-scale-factor" ctrlMaps'
                      (Just (TrigHub1 tr)) = Map.lookup "barcode-ocr-trigger" ctrlMaps'

                  let subRect = toRect $ HRect (V2 (round x) (round y)) (V2 (round w) (round h))
                      r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear

                  when (isEvent isGen) $ do
                    case r of
                      (Left _) -> return ()
                      (Right r) -> bgSubApply backSub 0 r >> return ()
                    return ()

                  (pos,size) <- get win

                  when changed $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always

                  when (isEvent restore) $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always


                  let FontSet{..} = fontSet
                  pushFont msyhlFont
                  result <- collapsingHeader "动作检测"
                  col $=! result
                  popFont

                  when result $ do
                    -- print $ "x " ++ show x ++ " y " ++ show y ++ " w " ++ show w ++ " h " ++ show h
                    withID ("barcode":: Text) $ do
                      dragFloat "lag" lag 0.01 0.1 1.0
                      sameLine
                      showHelp msyhlFont "检测到产品放入工装的动作开始，直到产品放置稳定之间的延迟"
                      dragFloat "scale" scale 0.1 1.0 10.0
                      sameLine
                      showHelp msyhlFont "条码图像输入OCR识别程序前的放大倍数，默认为1就行，数值太大，OCR识别速度变慢"

                      case r of
                        (Left _) -> return ()
                        (Right r) -> do
                          fg <- bgSubApply backSub 0 r
                          fgBgr <- exceptErrorIO $ cvtColor gray bgr fg
                          let pic = matFlip fgBgr FlipVertically
                              [h,w] = miShape $ matInfo pic
                              per = (sumImage2 pic)/(fromIntegral (h*w*255))
                              per' = if per > 0.99 then 0.99 else per
                          progressBar2 (realToFrac per) (Just (T.pack ((drop 2 (printf "%0.2f" per')) ++ "%")))
                          sameLine2
                          text "trigger"
                          sameLine
                          showHelp msyhlFont "移动侦测指示器，用于检测产品是否移动到位"
                          return ()

                    when (sg == (Running 1)) $ do
                      setNextWindowPos pos ImGuiCond_Always Nothing
                      setNextWindowSize size ImGuiCond_Always
                    bracket_ (begin3 "动作预览") end $ do

                      let src' = matFlip src FlipVertically
                      glBindTexture GL_TEXTURE_2D texId
                      withMatData src' $ (\step ptr-> do
                        let [h,w] = miShape $ matInfo src'
                        glTexImage2D GL_TEXTURE_2D 0
                          GL_RGB 
                          w h
                          0 GL_RGB GL_UNSIGNED_BYTE
                          (castPtr ptr))

                      ImVec2 w h <- get size
                      ImVec2 px py <- get pos
                      let [h2,w2] = miShape $ matInfo src
                          [h3,w3] = [fromIntegral h2, fromIntegral w2]

                      Foreign.with (ImVec2 w h) \sizePtr ->
                        Foreign.with (ImVec2 (px/w3) (py/h3)) \uv0Ptr ->
                          Foreign.with (ImVec2 ((px + w)/w3) ((py + h)/h3)) \uv1Ptr ->
                            Foreign.with (ImVec4 1 1 1 1) \tintColPtr ->
                              Foreign.with (ImVec4 1 1 1 0.5) \bgColPtr ->
                                image (intPtrToPtr $ fromIntegral texId) sizePtr uv0Ptr uv1Ptr tintColPtr bgColPtr

                      a <- getWindowPos
                      pos $=! a
                      b <- getWindowSize
                      size $=! b

                    return ()

                  case r of
                    (Left _) -> do
                      matOut <- newEmptyMat
                      return $ unsafeCoerceMat matOut
                    (Right r) -> return r
                  -- return src
                  ), oe')

  where
    trackInt = sscan (\(acc, change) a-> if a /= acc then (a, True) else (a, False)) (1, False)







opencvCanny :: SF GameInput ChainSF
opencvCanny = myAux Init
  where
    myAux sg = dSwitch (opencvCanny' sg) myAux

opencvCanny' :: Stage -> SF GameInput (ChainSF, Event Stage)
opencvCanny' sg = proc oi -> do
  let (Just (DragItem1 b10)) = Map.lookup "opencv-canny-threshold1" (giCtrl oi)
      (Just (DragItem1 b11)) = Map.lookup "opencv-canny-threshold2" (giCtrl oi)
      (Just (PinItem1 b20)) = Map.lookup "opencv-canny-enable" (giCtrl oi)
      ae = gate (Event (Running 1)) (sg == Init)
      oe = mergeEvents [ae]

  oe' <- iPre noEvent -< oe

  returnA -< ((\env ctrlMaps fontSet src -> do
                  let FontSet{..} = fontSet
                  pushFont msyhlFont
                  result <- collapsingHeader "视觉处理<Canny>"
                  popFont

                  pushFont droidFont
                  when result $ do
                    ctrlMaps' <- get ctrlMaps
                    let (Just (DragHub1 thres1)) = Map.lookup "opencv-canny-threshold1" ctrlMaps'
                        (Just (DragHub1 thres2)) = Map.lookup "opencv-canny-threshold2" ctrlMaps'
                        (Just (PinHub1 enable)) = Map.lookup "opencv-canny-enable" ctrlMaps'
                    dragFloat "Threshold1" thres1 1.0 1.0 300.0
                    sameLine
                    showHelp msyhlFont "canny算法的第一个参数"
                    dragFloat "Threshold2" thres2 1.0 1.0 300.0
                    sameLine
                    showHelp msyhlFont "canny算法的第二个参数"

                    checkbox "Enable" enable
                    sameLine
                    showHelp msyhlFont "是否开启canny算法，主要在调试工装光线的时候临时使用"
                    return ()

                  popFont
                  return $ do
                    if b20 then
                      exceptError $ cvtColor rgb gray src >>= canny (realToFrac b10) (realToFrac b11) Nothing CannyNormL1 >>= cvtColor gray rgb
                    else src
                  ), oe')


serialNumOCR :: SF GameInput ChainSF2
serialNumOCR = myAux Init
  where
    myAux sg = dSwitch (serialNumOCR' sg) myAux

serialNumOCR' :: Stage -> SF GameInput (ChainSF2, Event Stage)
serialNumOCR' sg = proc oi -> do
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
  wpM <- winPeriod -< oi

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
                      (Just (CombHub1 bankSelection)) = Map.lookup "serial-number-bank" ctrlMaps'

                  when (isEvent isGen) $ do
                    print "I am in init"
                    forkIO $ procSerialNum ocr submit collect
                    forkIO $ procSerialNum ocr submit_batch collect_batch
                    return ()

                  (pos,size) <- get win

                  when changed $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always

                  when (isEvent restore) $ do
                    setNextWindowPos pos ImGuiCond_Always Nothing
                    setNextWindowSize size ImGuiCond_Always

                  let subRect = toRect $ HRect (V2 ((round x)+(round b40)+fromIntegral b12) ((round y)+(round b41)+fromIntegral b13)) (V2 (round (w/b10-10)) (round (h/b10-15)))
                      r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                  wpM ctrlMaps r ocr

                  when (isEvent b21') $ do
                      let subRect = toRect $ HRect (V2 ((round x)+(round b40)+fromIntegral b12) ((round y)+(round b41)+fromIntegral b13)) (V2 (round (w/b10-10)) (round (h/b10-15)))
                          r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                      case r of
                        (Left _) -> return ()
                        (Right r) -> atomically $ writeTChan submit_batch r
                      return ()


                  let FontSet{..} = fontSet
                  pushFont msyhlFont
                  result <- collapsingHeader "序列号识别"
                  col $=! result
                  popFont

                  when result $ do
                    bracket_ (pushFont msyhlFont) popFont $ do
                      combo "银行" bankSelection (map (T.pack . fst) bankRecipes)
                      sameLine
                      showHelp msyhlFont "平安银行：比较OCR结果末尾16位；郑州银行：比较末尾12位。比较前去除非字母数字字符。"
                    withID ("serial number":: Text) $ do
                      dragFloat "ratio" ratio 0.1 1.0 4.0
                      sameLine
                      showHelp msyhlFont "调整序列号预览窗口的放大倍数，当图像比较小的时候，调整图像大小，便于人工观察"
                      dragFloat "scale" scale 0.1 1.0 10.0
                      sameLine
                      showHelp msyhlFont "序列号图像输入OCR识别程序前的放大倍数，如果刻字间距太密导致识别率低，可以调整这个放大倍数"
                      dragFloat2 "offSet" rx 1.0 0.0 500.0
                      sameLine
                      showHelp msyhlFont "序列号预览窗口的位置偏移，当序列号坐标太靠近屏幕下边沿或者右边沿，预览窗口显示不全的时候，配合预览窗口放大倍数进行调整"

                    clicked <- withID ("serial number":: Text) $ button "评估"
                    sameLine
                    showHelp msyhlFont "识别选中区域中的序列号，将结果显示在日志窗口，用于序列号的OCR识别区域的标定"
                    when clicked $ do

                      let subRect = toRect $ HRect (V2 ((round x)+(round b40)+fromIntegral b12) ((round y)+(round b41)+fromIntegral b13)) (V2 (round (w/b10-10)) (round (h/b10-15)))
                          r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                      case r of
                        (Left _) -> return ()
                        (Right r) -> do
                          atomically $ writeTChan submit r
                      return ()

                    when (sg == (Running 1)) $ do
                      setNextWindowPos pos ImGuiCond_Always Nothing
                      setNextWindowSize size ImGuiCond_Always
                    bracket_ (begin3 "序列号预览") end $ do

                      let src' = matFlip src FlipVertically
                      glBindTexture GL_TEXTURE_2D texId
                      withMatData src' $ (\step ptr-> do
                        let [h,w] = miShape $ matInfo src'
                        glTexImage2D GL_TEXTURE_2D 0
                          GL_RGB 
                          w h
                          0 GL_RGB GL_UNSIGNED_BYTE
                          (castPtr ptr))

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

                  let subRect = toRect $ HRect (V2 ((round x)+(round b40)+fromIntegral b12) ((round y)+(round b41)+fromIntegral b13)) (V2 (round (w/b10-10)) (round (h/b10-15)))
                      r = runExcept $ cvtColor rgb bgr (matFlip src FlipVertically) >>= (flip matSubRect) subRect >>= (\img-> return $ matFlip (matTranspose img) FlipVertically) >>= cvtColor bgr rgb >>= resize (ResizeRel $ pure (realToFrac b11)) InterLinear
                  case r of
                    (Left _) -> do
                      matOut <- newEmptyMat
                      return $ unsafeCoerceMat matOut
                    (Right r) -> return r
                  -- return src
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
