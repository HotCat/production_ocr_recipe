
{-# LANGUAGE Arrows #-}
{-# LANGUAGE RecordWildCards     #-}

module Parser (ParsedInput(..)
              , GameInput(..)
              , parseKeyInput) where

import           FRP.Yampa
import           Linear
import           Object
import           Graphics.UI.GLFW

data GameInput = GameInput {
        giPDS  :: PDState
     ,  giKey  :: TeachPad
     ,  giCtrl :: CtrlPad
} deriving (Eq, Show)


------------------------------------------------------------------------------
-- Pointing device processing
------------------------------------------------------------------------------

-- State of the pointing device.
-- The points for pdsLeft, pdsRight, and pdsDrag reflect where the button
-- was initially pressed.


data PDState = PDState {
    pdsPos          :: V2 Double,                 -- Current position.
    pdsDragStartPos :: V2 Double,                 -- (Last) drag start position.
    pdsDragVec      :: V2 Double,              -- (Latest) drag vector.
    pdsLeft         :: Maybe (V2 Double),         -- Left button currently down.
    pdsRight        :: Maybe (V2 Double),         -- Right button currently down.
    pdsDrag         :: Maybe (V2 Double)          -- Currently dragging.
} deriving (Eq, Show)


-- Initial state.
initPDS = PDState {
              pdsPos          = V2 0 0,
              pdsDragStartPos = V2 0 0,
              pdsDragVec      = V2 0 0,
              pdsLeft         = Nothing,
              pdsRight        = Nothing,
              pdsDrag         = Nothing
          }


data ParsedInput =
  ParsedInput { wCount :: Double, aCount :: Double,
                sCount :: Double, dCount :: Double,
                upEvs  :: Event MyInput, downEvs :: Event MyInput,
                rightEvs :: Event MyInput, leftEvs :: Event MyInput,
                xPos   :: Double, yPos :: Double, yOffset :: Float
                }

data KeyInput = KeyInput Double Double Double Double (Event MyInput) (Event MyInput) (Event MyInput) (Event MyInput)

wiToPDS :: SF (Event Int) PDState
wiToPDS = accumHoldBy nextPDS initPDS


nextPDS :: PDState -> Int -> PDState
nextPDS pds _ = pds


-- filterKeyDowns :: SF (Event MyInput)  (Event MyInput)
-- filterKeyDowns = arr $ filterE ((==KeyState'Pressed) . keyState)


-- keyIntegral :: Double -> SF (Event a) Double
-- keyIntegral a = let eventToSpeed (Event _) = a
--                     eventToSpeed NoEvent = 0
--                 in arr eventToSpeed >>> integral

-- parseKeyInput :: SF WinInput KeyInput
-- parseKeyInput = proc WinInput{..} -> do
--   down      <- filterKeyDowns        -< keyInput
--   wCount    <- countKey Key'W        -< down
--   aCount    <- countKey Key'A        -< down
--   sCount    <- countKey Key'S        -< down
--   dCount    <- countKey Key'D        -< down
--   upEvs     <- filterKey Key'Up      -< down
--   downEvs   <- filterKey Key'Down    -< down
--   rightEvs  <- filterKey Key'Right   -< down
--   leftEvs   <- filterKey Key'Left    -< down

--   returnA -< KeyInput wCount aCount sCount dCount upEvs downEvs rightEvs leftEvs

--   where
--     countKey c = filterE ((== c) . key) ^>> keyIntegral 1
--     filterKey k = arr $ filterE ((==k) . key)

parseKeyInput :: SF WinInput GameInput
parseKeyInput = proc wi -> do
  returnA -< GameInput {giPDS = initPDS, giKey = (keyInput >>> allKeys) wi, giCtrl = (uiInput >>> allCtrls) wi}

  
