{-# LANGUAGE QuasiQuotes #-}
{-# language DeriveTraversable #-}
{-# LANGUAGE BangPatterns #-}

module Object (MyInput(..)
             , WinInput(..)
             , Stage(..)
             , TeachPad
             , CtrlPad
             , CtrlRef
             , Keyboard(..)
             , CtrlItem(..)
             , FontSet(..)
             , fmtString
             , configTemplate1
             , configTemplate2
             , configTemplate3
             , configTemplate4
             , configTemplate5
             , configTemplate6
             , captionHelp
              ) where

import           Graphics.UI.GLFW
import           FRP.Yampa (SF, Event)
import           Linear
import           Data.IORef
import qualified Data.Map.Strict as Map
import           Text.RawString.QQ
import           Language.Scheme.Types

import           Graphics.GL
import           Foreign.Ptr
import           System.Random
import           Control.DeepSeq (NFData (rnf))

-- StateVar
import Data.StateVar
  ( HasGetter(get), HasSetter, ($=!) )


instance NFData VisionMonad where
  rnf obj = obj `seq` ()

fmtString = [r|(set-camera-property mycam "%s" %f)|]

configTemplate1 = [r|  (load-system-property all-controls-references "%s" %f)
|]
configTemplate2 = [r|  (load-system-property all-controls-references "%s" %f %f %f)
|]
configTemplate3 = [r|  (load-system-property all-controls-references "%s" %s)
|]
configTemplate4 = [r|  (load-system-property all-controls-references "%s" '(%f %f %f %f))
|]
configTemplate5 = [r|  (load-system-property all-controls-references "%s" '(%f %f))
|]
configTemplate6 = [r|  (load-system-property all-controls-references "%s" %d)
|]

captionHelp = [r|第一个参数可以叠加飞天的logo，不影响OCR识别
第二个参数控制图像的几何变换，不影响OCR识别
第三个参数控制图像的FOV视场，不影响OCR识别
按c键开始OCR识别。遇到个别不好识别的产品，
可以临时调整摄像头参数，识别区域。
识别完成后按x键恢复当前配置，
长按Ok,Ng显示区域3秒实现清零
|]

data MyInput = CursorPos {pt :: !(V2 Double)}
             | MouseButton {mouseButton :: !(MouseButton), mouseState :: !(MouseButtonState)}
             | KeyStroke {allKeys :: !TeachPad}
             | CtrlData {allCtrls :: !CtrlPad}

data Keyboard = Keyboard {key :: !Key, keyState :: !KeyState, modifiers :: !ModifierKeys} deriving (Eq, Show)

data WinInput = WinInput {cursorInput :: !(Event MyInput), buttonInput :: !(Event MyInput), keyInput :: !MyInput, uiInput :: !MyInput}


data CtrlItem = DragItem1 !Float
               | DragItem2 !(Float, Float)
               | DragItem3 !(Float, Float, Float)
               | CombItem1 !Int
               | PinItem1 !Bool
               | RectItem4 !(Float, Float, Float, Float)
               | StrItem2 !(String, String)
               | OcrItem1 !OcrState
               | SeedItem1 !StdGen
               | StochItem2 !(Int, Int)
               | TrigItem1 !(Maybe String)
               | CompItem1 !(Maybe Compound)
              deriving (Eq, Show)

type TeachPad = (Map.Map Key Keyboard)

type CtrlPad = (Map.Map String CtrlItem)

data Stage = Init
           | Running Int deriving (Eq, Show, Read)

-- Rebuild syntax enables us to keep fonts in any
-- traversable type, so let's make our life a little easier.
-- But feel free to use lists or maps.
data FontSet a = FontSet
  { droidFont :: a
  , droidFont2 :: a
  , defaultFont :: a
  , notoFont :: a
  , myFont :: a
  , rabbitFont :: a
  , msyhlFont :: a
  }
  deriving (Functor, Foldable, Traversable)


