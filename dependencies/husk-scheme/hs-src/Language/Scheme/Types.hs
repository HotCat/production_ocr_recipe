{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}

{- |
Module      : Language.Scheme.Types
Copyright   : Justin Ethier
Licence     : MIT (see LICENSE in the distribution)

Maintainer  : github.com/justinethier
Stability   : experimental
Portability : portable

This module contains top-level data type definitions, environments, error types, and associated functions.

-}

module Language.Scheme.Types
    ( 
    -- * Environments
      Env (..)
    , nullEnv 
    -- * Error Handling
    , LispError (..)
    , CtrlHub(..)
    , paramZoos
    , OcrState(..)
    , DevSlot(..)
    , Compound(..)
    , CtrlRef
    , VisionMonad(..)
    , ThrowsError 
    , IOThrowsError 
    , liftThrows 
    , showCallHistory
    -- * Types and related functions
    , LispVal (
          Atom
        , List
        , DottedList
        , Vector
        , ByteVector
        , HashTable
        , Number
        , Float
        , Complex
        , Rational
        , String
        , Char
        , Bool
        , PrimitiveFunc
        , Func
             , params
             , vararg
             , body
             , closure
        , HFunc
             , hparams
             , hvararg
             , hbody
             , hclosure
        , IOFunc
        , CustFunc
        , EvalFunc
        , Pointer
             , pointerVar
             , pointerEnv
        , Opaque
        , Port
        , Vision
        , AllConfigs
        , MatPipe
        , MatAffine
        , CameraDataM
        , CameraDataH
        , CameraDataV
        , ModbusDataZ
        , ProjectContext
        , RenderContext
        , ReconstructContext
        , ShaderAction
        , ShaderProgram
        , Continuation
             , contClosure
             , currentCont
             , nextCont
             , dynamicWind
             , contCallHist
        , Syntax
             , synClosure
             , synRenameClosure
             , synDefinedInMacro
             , synEllipsis
             , synIdentifiers
             , synRules
        , SyntaxExplicitRenaming
        , LispEnv
        , EOF
        , Nil)
    , nullLisp
    , toOpaque
    , fromOpaque
    , DeferredCode (..)
    , DynamicWinders (..)
    , makeNullContinuation 
    , makeCPS 
    , makeCPSWArgs 
    , eqv 
    , eqvList
    , eqVal 
    , box
    , makeFunc
    , makeNormalFunc
    , makeVarargs
    , makeHFunc
    , makeNormalHFunc
    , makeHVarargs
    , validateFuncParams
    , loadCamFrame
    , renderImage
    , obtainImage
    , saveImage
    , getImg
    )
 where
import Control.Monad.Except
import Data.Complex
import Data.Array
import qualified Data.ByteString as BS
import Data.Dynamic
import qualified Data.Knob as DK
import qualified Data.List as DL
import Data.IORef
import qualified Data.Map
-- import Data.Maybe
import Data.Ratio
import System.IO
import Text.ParserCombinators.Parsec hiding (spaces)
import Numeric

import DearImGui
import Data.Word
import Data.Text (Text)
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

import Linear.V2 ( V2(..) )
import Linear.V3 ( V3(..) )
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.Vector.Storable   (Vector)
import qualified Data.Vector.Storable   as V

import           Codec.Picture
import           Codec.Picture.Extra    (flipVertically)
import           Codec.Picture.Types
import qualified Codec.Picture.Types    as CPTI

import Data.List (intercalate, isSuffixOf, isPrefixOf)

import Device.Camera.Mindvision
import Device.Camera.Hikvision
import Device.Camera.VirtualCam
import Device.Motion.ZMotion
import Device.Projector.ChiMei
import Device.Pointcloud.Profilometry
import Device.Pointcloud.SceneRender
import Graphics.GL
import Foreign.Ptr

import Data.Time.Clock
import Data.Time.Format
import Data.Time.Clock.POSIX

import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent
import Control.Concurrent.STM.TChan

import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq

import Linear

-- Environment management

-- |A Scheme environment containing variable bindings of form @(namespaceName, variableName), variableValue@
data Env = Environment {
        parentEnv :: (Maybe Env), 
        bindings :: (IORef (Data.Map.Map String (IORef LispVal))),
        pointers :: (IORef (Data.Map.Map String (IORef [LispVal])))
    }

instance Eq Env where
    (Environment _ xb xpts) == (Environment _ yb ypts) = 
      (xb == yb) && (xpts == ypts)


instance Show (IORef a) where
  show _ = "<ioref>"

instance Show (TChan a) where
  show _ = "<tchan>"

data DevSlot = Inserted
             | Removed deriving (Eq,Show)

data OcrState = OcrPass
              | OcrFail
              | OcrPending
              | OcrUnknown
              deriving (Eq, Show)

data Compound = Compound {serBase :: !String, serBody :: !Integer, serStart :: !Int, serEnd :: !Int} deriving (Eq, Show)

data CtrlHub = DragHub1 !(IORef Float)
              | DragHub2 !(IORef (Float, Float))
              | DragHub2d !(IORef (Double, Double))
              | DragHub3 !(IORef (Float, Float, Float))
              | DragHub3d !(IORef (Maybe (Double, Double, Double)))
              | DragHub4d !(IORef (Maybe (Double, Double, Double, Double)))
              | DragHub1iM !(IORef (Maybe Int))
              | DragHubV3dM !(IORef (Maybe (V3 Double)))
              | DragHub1i !(IORef Int)
              | CombHub1 !(IORef Int)
              | RadioHub1 !(IORef Int)
              | AxisHub1 !(IORef Double)
              | PinHub1 !(IORef Bool)
              | PinHub2 !(IORef (Bool, Bool))
              | RectHub4 !(IORef (IORef ImVec2, IORef ImVec2))
              | UTCHub1   !UTCTime
              | TexIdHub1 !GLuint
              | ChanHub1 !(TChan (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))
              | ChanHub2 !(TChan String)
              | ChanHub3 !(TChan ((Mat ('S ['D, 'D]) ('S 3) ('S Word8)), Int))
              | ChanHub4 !(TChan ((Mat ('S ['D, 'D]) ('S 3) ('S Word8)), Int, Int))
              | ChanHub5 !(TChan [Bool])
              | ChanHub6 !(TChan (CameraMv, Reconstruct, Int))
              | ChanHub7 !(TChan (Reconstruct, (M44 Float), Int))
              | ChanHub8 !(TChan (Reconstruct, (M44 Float), (M44 Float), [V3 Double], [V3 Double]))
              | ChanHub9 !(TChan Reconstruct)
              | ChanHub10 !(TChan Int)
              | HandleHub1 !(IORef (Maybe Handle))
              | MatHub1 !(IORef (Maybe (Mat ('S ['D, 'D]) ('S 3) ('S Word8))))
              | FifoHub1 !(IORef (Seq.Seq Double))
              | StrHub1 !(IORef String)
              | StrHub2 !(IORef (String, String))
              | TextHub1 !(IORef Text)
              | OcrHub1 !(IORef OcrState)
              | StochHub2 !(IORef (Int, Int))
              | TrigHub1 !(IORef (Maybe String))
              | CompHub1 !(IORef (Maybe Compound))
              | PitsHub1 !(IORef (Maybe (Mat ('S ['D, 'D]) ('S 3) ('S Word8))))
              | DevHub1 !(IORef (Map.Map String DevSlot))
              | ParHub1 !(IORef (Map.Map String (DevSlot, Bool)))
              | RefHub2 !(IORef Float, IORef Float)
              | RefHub2b !(IORef Bool, IORef Bool)
              | RefHub5b !(IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool)
              | RefHub6b !(IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool)
              | RefHub10b !(IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool)
              | RefHub12b !(IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool, IORef Bool)
              | RefHub4 !(IORef (Maybe Float), IORef (Maybe Float), IORef (Maybe Float), IORef (Maybe Float))
              | RefHub4i !(IORef (Maybe Int), IORef (Maybe Int), IORef (Maybe Int), IORef (Maybe Int))
              | RefHub4s !(IORef (Maybe String), IORef (Maybe String), IORef (Maybe String), IORef (Maybe String))
              | RefHub5d3 !(IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)))
              | RefHub5v3 !(IORef (Maybe [V3 Double]), IORef (Maybe [V3 Double]), IORef (Maybe [V3 Double]), IORef (Maybe [V3 Double]), IORef (Maybe [V3 Double]))
              | RefHub6d3 !(IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)))
              | RefHub10d3 !(IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)), IORef (Maybe (V3 Double)))
              | LstHubV3d !(IORef (Maybe [V3 Double]))
              | LstHub1i !(IORef [IORef Bool])
              | LstHub1iM !(IORef (Maybe [Int]))
              | ThreadHub1 !(IORef (Map.Map String ThreadId))
              | RefHub3m44f !(IORef ((M44 Float), (M44 Float), (M44 Float)))
              | RefHub1m44f !(IORef (M44 Float))
              | ColorHub4 !(IORef ImVec4)
              deriving (Eq, Show)

type CtrlRef = (Data.Map.Map String CtrlHub)

paramZoos = ["gauss-sigmas", "watershed-maxDepth", "morphology-opening-se", "simplify-tolerance", "watershed-connectivity", "growregions-iter", "measurement-size", "measurement-perimeter", "watershed-correct", "number-of-circles", "algorithm-identifier"]

-- |An empty environment
nullEnv :: IO Env
nullEnv = do 
    nullBindings <- newIORef $ Data.Map.fromList []
    nullPointers <- newIORef $ Data.Map.fromList []
    return $ Environment Nothing nullBindings nullPointers

-- |Types of errors that may occur when evaluating Scheme code
data LispError = NumArgs (Maybe Integer) [LispVal] -- ^Invalid number of function arguments
  | TypeMismatch String LispVal -- ^Type error
  | Parser ParseError -- ^Parsing error
  | BadSpecialForm String LispVal -- ^Invalid special (built-in) form
  | UnboundVar String String -- ^ A referenced variable has not been declared
  | DivideByZero -- ^Divide by Zero error
  | NotImplemented String -- ^ Feature is not implemented
  | InternalError String {- ^An internal error within husk; in theory user (Scheme) code
                         should never allow one of these errors to be triggered. -}
  | Default String -- ^Default error
  | ErrorWithCallHist LispError [LispVal] -- ^Wraps an error to also include the current call history

-- |Create a textual description for a 'LispError'
showError :: LispError -> String
showError (NumArgs (Just expected) found) = "Expected " ++ show expected
                                  ++ " args but found " 
                                  ++ (show $ length found)
                                  ++ " values: " ++ unwordsList found
showError (NumArgs Nothing found) = "Incorrect number of args, "
                                    ++ " found "
                                    ++ (show $ length found)
                                    ++ " values: " ++ unwordsList found
showError (TypeMismatch expected found) = "Invalid type: expected " ++ expected
                                  ++ ", found " ++ show found
showError (Parser parseErr) = "Parse error at " ++ ": " ++ show parseErr
showError (BadSpecialForm message form) = message ++ ": " ++ show form
showError (UnboundVar message varname) = message ++ ": " ++ varname
showError (DivideByZero) = "Division by zero"
showError (NotImplemented message) = "Not implemented: " ++ message
showError (InternalError message) = "An internal error occurred: " ++ message
showError (Default message) = "Error: " ++ message
showError (ErrorWithCallHist err stack) = showCallHistory (show err) stack

instance Show LispError where show = showError

-- |Display call history for an error
showCallHistory :: String -> [LispVal] -> String
showCallHistory message hist = do
  let nums :: [Int]
      nums = [0..]
      ns = take (length hist) nums
  message ++ "\n\nCall History:\n" ++ 
    (unlines $ map (\(n, s) -> ('#' : show n) ++ ": " ++ show s) 
                   (zip ns $ reverse hist))

-- |Container used by operations that could throw an error
type ThrowsError = Either LispError

-- |Container used to provide error handling in the IO monad
type IOThrowsError = ExceptT LispError IO

-- |Lift a ThrowsError into the IO monad
liftThrows :: ThrowsError a -> IOThrowsError a
liftThrows (Left err) = throwError err
liftThrows (Right val) = return val

data VisionMonad = Individual !(IO ()) -- !(IO (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))
                 | Individual2 !((Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO ())
                 | DaisyChain !((Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))
                 | DaisyChain2 !((Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> IO (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))

-- |Scheme data types
data LispVal = Atom String
 -- ^Symbol
 | List [LispVal]
 -- ^List
 | DottedList [LispVal] LispVal
 -- ^Pair
 | Vector (Array Int LispVal)
 -- ^Vector
 | ByteVector BS.ByteString
 -- ^ByteVector from R7RS
 | HashTable (Data.Map.Map LispVal LispVal)
 {- ^Hash table.
 Technically this could be a derived data type instead of being built-in to the
 interpreter. And perhaps in the future it will be. But for now, a hash table
 is too important of a data type to not be included. -}
 --
 -- Map is technically the wrong structure to use for a hash table since it is based on a binary tree and hence operations tend to be O(log n) instead of O(1). However, according to <http://www.opensubscriber.com/message/haskell-cafe@haskell.org/10779624.html> Map has good performance characteristics compared to the alternatives. So it stays for the moment...
 --
 | Number Integer -- ^Integer number
 {- FUTURE: rename this to @Integer@ (or @WholeNumber@ or something else more meaningful)
 Integer -}
 | Float Double -- ^Double-precision floating point number
 {- FUTURE: rename this @Real@ instead of @Float@...
 Floating point -}
 | Complex (Complex Double)
 -- ^Complex number
 | Rational Rational
 -- ^Rational number
 | String String
 -- ^String
 | Char Char
 -- ^Character
 | Bool Bool
 -- ^Boolean
 | PrimitiveFunc ([LispVal] -> ThrowsError LispVal)
 -- ^Primitive function
 | Func {params :: [String],
         vararg :: (Maybe String),
         body :: [LispVal],
         closure :: Env
        }
 -- ^Function written in Scheme
 | HFunc {hparams :: [String],
          hvararg :: (Maybe String),
          hbody :: (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal),
          hclosure :: Env
        }
 -- ^Function formed from a Haskell function
 | IOFunc ([LispVal] -> IOThrowsError LispVal)
 -- ^Primitive function within the IO monad
 | EvalFunc ([LispVal] -> IOThrowsError LispVal)
 {- ^Function within the IO monad with access to
 the current environment and continuation. -}
 | CustFunc ([LispVal] -> IOThrowsError LispVal)
 -- ^A custom function written by code outside of husk.
 --  Any code that uses the Haskell API should define custom
 --  functions using this data type.
 | Pointer { pointerVar :: String
            ,pointerEnv :: Env } 
 -- ^Pointer to an environment variable.
 | Opaque Dynamic
 -- ^Opaque Haskell value.
 | Port Handle (Maybe DK.Knob)
 -- ^I/O port
 -- | Vision (IO (Mat ('S ['D, 'D]) ('S 3) ('S Word8)))
 | Vision !VisionMonad
 | AllConfigs !(IORef CtrlRef)
 | CameraDataM !CameraMv
 | CameraDataH !CameraHv
 | CameraDataV !CameraVi
 | ProjectContext !Projector
 | ReconstructContext !Reconstruct
 | ShaderAction !(GLuint -> String -> IO ())
 | ShaderProgram !GLuint
 | RenderContext !GLResources
 | MatPipe !(Mat ('S ['D, 'D]) ('S 3) ('S Word8))
 | ModbusDataZ !ModbusZv
 | MatAffine !(Mat (ShapeT [2, 3]) ('S 1) ('S Double))
 | Continuation {  contClosure :: Env                   -- Environment of the continuation
                 , currentCont :: (Maybe DeferredCode)  -- Code of current continuation
                 , nextCont :: (Maybe LispVal)          -- Code to resume after body of cont
                 , dynamicWind :: (Maybe [DynamicWinders]) -- Functions injected by (dynamic-wind)
                 , contCallHist :: [LispVal] -- Active call history
                }
 -- ^Continuation
 | Syntax { synClosure :: Maybe Env       -- ^ Code env in effect at definition time, if applicable
          , synRenameClosure :: Maybe Env -- ^ Renames (from macro hygiene) in effect at def time;
                                          --   only applicable if this macro defined inside another macro.
          , synDefinedInMacro :: Bool     -- ^ Set if macro is defined within another macro
          , synEllipsis :: String         -- ^ String to use as the ellipsis identifier
          , synIdentifiers :: [LispVal]   -- ^ Literal identifiers from syntax-rules 
          , synRules :: [LispVal]         -- ^ Rules from syntax-rules
   } -- ^ Type to hold a syntax object that is created by a macro definition.
     --   Syntax objects are not used like regular types in that they are not
     --   passed around within variables. In other words, you cannot use set! to
     --   assign a variable to a syntax object. But they are used during function
     --   application. In any case, it is convenient to define the type here 
     --   because syntax objects are stored in the same environments and 
     --   manipulated by the same functions as regular variables.
 | SyntaxExplicitRenaming LispVal
   -- ^ Syntax for an explicit-renaming macro
 | LispEnv Env
   -- ^ Wrapper for a scheme environment
 | EOF
   -- ^ End of file indicator
 | Nil String
 -- ^Internal use only; do not use this type directly.

-- | Scheme /null/ value
nullLisp :: LispVal
nullLisp = List []

-- |Convert a Haskell value to an opaque Lisp value.
toOpaque :: Typeable a => a -> LispVal
toOpaque = Opaque . toDyn

-- |Convert an opaque Lisp value back into a Haskell value of the appropriate
--  type, or produce a TypeMismatch error.
fromOpaque :: forall a. Typeable a => LispVal -> ThrowsError a
-- fromOpaque (Opaque o) | isJust $ fromDynamic o = fromJust $ fromDynamic o
-- fromOpaque badArg = throwError $ TypeMismatch (show $ toOpaque (undefined :: a)) badArg

-- Old version that used ViewPatterns
fromOpaque (Opaque (fromDynamic -> Just v)) = return v
fromOpaque badArg = throwError $ TypeMismatch (show $ toOpaque (undefined :: a)) badArg

-- |Container to hold code that is passed to a continuation for deferred execution
data DeferredCode =
    SchemeBody [LispVal] | -- ^A block of Scheme code
    HaskellBody {
       contFunction :: (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal)
     , contFunctionArgs :: (Maybe [LispVal]) -- Arguments to the higher-order function
    } -- ^A Haskell function

-- |Container to store information from a dynamic-wind
data DynamicWinders = DynamicWinders {
    before :: LispVal -- ^Function to execute when resuming continuation within extent of dynamic-wind
  , after :: LispVal -- ^Function to execute when leaving extent of dynamic-wind
}

showDWVal :: DynamicWinders -> String
showDWVal (DynamicWinders b a) = "(" ++ (show b) ++ " . " ++ (show a) ++ ")"

instance Show DynamicWinders where show = showDWVal

-- |Make an /empty/ continuation that does not contain any code
makeNullContinuation :: Env -> LispVal
makeNullContinuation env = Continuation env Nothing Nothing Nothing []

-- |Make a continuation that takes a higher-order function (written in Haskell)
makeCPS :: Env 
        -- ^ Environment
        -> LispVal 
        -- ^ Current continuation
        -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal) 
        -- ^ Haskell function
        -> LispVal
        -- ^ The Haskell function packaged as a LispVal
makeCPS env cont@(Continuation {contCallHist=hist}) cps = Continuation env (Just (HaskellBody cps Nothing)) (Just cont) (dynamicWind cont) hist
makeCPS env cont cps = Continuation env (Just (HaskellBody cps Nothing)) (Just cont) Nothing [] -- This overload just here for completeness; it should never be used

-- |Make a continuation that stores a higher-order function and arguments to that function
makeCPSWArgs :: Env
        -- ^ Environment
        -> LispVal 
        -- ^ Current continuation
        -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal) 
        -- ^ Haskell function
        -> [LispVal]
        -- ^ Arguments to the function
        -> LispVal
        -- ^ The Haskell function packaged as a LispVal
makeCPSWArgs env cont@(Continuation {dynamicWind=dynWind,contCallHist=hist}) cps args = 
    Continuation 
        env 
        (Just (HaskellBody cps (Just args))) 
        (Just cont) dynWind hist
makeCPSWArgs env cont cps args = 
    -- This overload just here for completeness; it should never be used
    Continuation 
        env 
        (Just (HaskellBody cps (Just args))) 
        (Just cont) Nothing []

instance Ord LispVal where
  compare (Bool a) (Bool b) = compare a b
  compare (Number a) (Number b) = compare a b
  compare (Rational a) (Rational b) = compare a b
  compare (Float a) (Float b) = compare a b
  compare (String a) (String b) = compare a b
  compare (Char a) (Char b) = compare a b
  compare (Atom a) (Atom b) = compare a b
{- compare (DottedList xs x) (DottedList xs x) = compare a b
Vector
HashTable
List
Func
Others? -}
  compare a b = compare (show a) (show b) -- Hack (??): sort alphabetically when types differ or have no handlers

-- |Compare two 'LispVal' instances
eqv :: [LispVal] 
    -- ^ A list containing two values to compare
    -> ThrowsError LispVal
    -- ^ Result wrapped as a Bool
eqv [(Bool arg1), (Bool arg2)] = return $ Bool $ arg1 == arg2
eqv [(Number arg1), (Number arg2)] = return $ Bool $ arg1 == arg2
eqv [(Complex arg1), (Complex arg2)] = return $ Bool $ arg1 == arg2
eqv [(Rational arg1), (Rational arg2)] = return $ Bool $ arg1 == arg2
eqv [(Float arg1), (Float arg2)] = return $ Bool $ arg1 == arg2
eqv [(String arg1), (String arg2)] = return $ Bool $ arg1 == arg2
eqv [(Char arg1), (Char arg2)] = return $ Bool $ arg1 == arg2
eqv [(Atom arg1), (Atom arg2)] = return $ Bool $ arg1 == arg2
eqv [(DottedList xs x), (DottedList ys y)] = eqv [List $ xs ++ [x], List $ ys ++ [y]]
eqv [(Vector arg1), (Vector arg2)] = eqv [List (elems arg1), List (elems arg2)]
eqv [(ByteVector a), (ByteVector b)] = return $ Bool $ a == b
eqv [(HashTable arg1), (HashTable arg2)] =
  eqv [List (map (\ (x, y) -> List [x, y]) $ Data.Map.toAscList arg1),
       List (map (\ (x, y) -> List [x, y]) $ Data.Map.toAscList arg2)]
--
-- This comparison function may be too simplistic. Basically we check to see if
-- functions have the same calling interface. If they do, then we compare the 
-- function bodies for equality.
--
--FUTURE:
--
-- The real solution for this and many of the other comparison functions is to
-- assign memory locations to data. Then we can just compare memory locations
-- in cases such as this one. But that is a much larger change.
eqv [x@(Func _ _ xBody _), y@(Func _ _ yBody _)] = do
  if (show x) /= (show y)
     then return $ Bool False
     else eqvList eqv [List xBody, List yBody] 
eqv [x@(HFunc{}), y@(HFunc{})] = do
  if (show x) /= (show y)
     then return $ Bool False
     else return $ Bool True
--
eqv [x@(PrimitiveFunc _), y@(PrimitiveFunc _)] = return $ Bool $ (show x) == (show y)
eqv [x@(IOFunc _), y@(IOFunc _)] = return $ Bool $ (show x) == (show y)
eqv [x@(CustFunc _), y@(CustFunc _)] = return $ Bool $ (show x) == (show y)
eqv [x@(EvalFunc _), y@(EvalFunc _)] = return $ Bool $ (show x) == (show y)
-- FUTURE: comparison of two continuations
eqv [l1@(List _), l2@(List _)] = eqvList eqv [l1, l2]
eqv [_, _] = return $ Bool False
eqv badArgList = throwError $ NumArgs (Just 2) badArgList

-- |Compare two lists of haskell values, using the given comparison function
eqvList :: ([LispVal] -> ThrowsError LispVal) -> [LispVal] -> ThrowsError LispVal
eqvList eqvFunc [(List arg1), (List arg2)] = 
    return $ Bool $ (length arg1 == length arg2) &&
                    all eqvPair (zip arg1 arg2)
    where eqvPair (x1, x2) = case eqvFunc [x1, x2] of
                               Left _ -> False
                               Right (Bool val) -> val
                               _ -> False -- OK?
eqvList _ _ = throwError $ Default "Unexpected error in eqvList"

-- |A more convenient way to call /eqv/
eqVal :: LispVal -> LispVal -> Bool
eqVal a b = do
  let result = eqv [a, b]
  case result of
    Left _ -> False
    Right (Bool val) -> val
    _ -> False -- Is this OK?

instance Eq LispVal where
  x == y = eqVal x y

-- |Create a textual description of a 'LispVal'
showVal :: LispVal -> String
showVal (Nil _) = ""
showVal (EOF) = "#!EOF"
showVal (LispEnv _) = "<env>"
showVal (String contents) = "\"" ++ contents ++ "\""
showVal (Char chr) = [chr]
showVal (Atom name) = name
showVal (Number contents) = show contents
showVal (Complex contents) = show (realPart contents) ++ "+" ++ (show $ imagPart contents) ++ "i"
showVal (Rational contents) = (show (numerator contents)) ++ "/" ++ (show (denominator contents))
showVal (Float contents) = showFFloat Nothing contents ""
showVal (Bool True) = "#t"
showVal (Bool False) = "#f"
showVal (Vector contents) = "#(" ++ unwordsList (Data.Array.elems contents) ++ ")"
showVal (ByteVector contents) = "#u8(" ++ unwords (map show (BS.unpack contents)) ++ ")"
showVal (HashTable _) = "<hash-table>"
showVal (List contents) = "(" ++ unwordsList contents ++ ")"
showVal (DottedList h t) = "(" ++ unwordsList h ++ " . " ++ showVal t ++ ")"
showVal (PrimitiveFunc _) = "<primitive>"
showVal (Continuation {}) = "<continuation>"
showVal (Syntax {}) = "<syntax>"
showVal (SyntaxExplicitRenaming _) = "<er-macro-transformer syntax>"
showVal (Func {params = args, vararg = varargs, body = _, closure = _}) =
  "(lambda (" ++ unwords args ++
    (case varargs of
      Nothing -> ""
      Just arg -> " . " ++ arg) ++ ") ...)"
showVal (HFunc {hparams = args, hvararg = varargs, hbody = _, hclosure = _}) =
  "(lambda (" ++ unwords args ++
    (case varargs of
      Nothing -> ""
      Just arg -> " . " ++ arg) ++ ") ...)"
showVal (Port _ _) = "<IO port>"
showVal (Vision _) = "<Vision monad>"
showVal (MatPipe _) = "<Mat Opencv>"
showVal (MatAffine _) = "<Mat Affine>"
showVal (CameraDataM _) = "<Camera MindVision>"
showVal (CameraDataH _) = "<Camera Hikvision>"
showVal (CameraDataV _) = "<Camera VirtualCam>"
showVal (ModbusDataZ _) = "<Modbus ZMotion>"
showVal (ProjectContext _) = "<Projector ChiMei>"
showVal (ReconstructContext _) = "<Reconstruct Profilometry>"
showVal (ShaderAction _) = "<Shader Action>"
showVal (ShaderProgram p) = "<Shader Program #" ++ show p ++ ">"
showVal (RenderContext _) = "<Scene Render>"
showVal (AllConfigs _) = "<AllConfig structure>"
showVal (IOFunc _) = "<IO primitive>"
showVal (CustFunc _) = "<custom primitive>"
showVal (EvalFunc _) = "<procedure>"
showVal (Pointer p _) = "<ptr " ++ p ++ ">"
showVal (Opaque d) = "<Haskell " ++ show (dynTypeRep d) ++ ">"

-- |A helper function to make pointer deref code more concise
box :: LispVal -> IOThrowsError [LispVal]
box a = return [a]

-- |Convert a list of Lisp objects into a space-separated string
unwordsList :: [LispVal] -> String
unwordsList = unwords . map showVal

-- |Allow conversion of lispval instances to strings
instance Show LispVal where show = showVal


-- Functions required by the interpreter --

-- |Create a scheme function
makeFunc :: -- forall (m :: * -> *).
            (Monad m) =>
            Maybe String -> Env -> [LispVal] -> [LispVal] -> m LispVal
makeFunc varargs env fparams fbody = return $ Func (map showVal fparams) varargs fbody env

-- |Create a normal scheme function
makeNormalFunc :: (Monad m) => Env
               -> [LispVal]
               -> [LispVal]
               -> m LispVal
makeNormalFunc = makeFunc Nothing

-- |Create a scheme function that can receive any number of arguments
makeVarargs :: (Monad m) => LispVal -> Env
                        -> [LispVal]
                        -> [LispVal]
                        -> m LispVal
makeVarargs = makeFunc . Just . showVal

-- Functions required by a compiled program --

-- |Create a haskell function
makeHFunc ::
            (Monad m) =>
            Maybe String 
         -> Env 
         -> [String] 
         -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal) 
--         -> String 
         -> m LispVal
makeHFunc varargs env fparams fbody = return $ HFunc fparams varargs fbody env --(map showVal fparams) varargs fbody env
-- |Create a normal haskell function
makeNormalHFunc :: (Monad m) =>
                  Env
               -> [String]
               -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal)
               -> m LispVal
makeNormalHFunc = makeHFunc Nothing

-- |Create a haskell function that can receive any number of arguments
makeHVarargs :: (Monad m) => LispVal 
                        -> Env
                        -> [String]
                        -> (Env -> LispVal -> LispVal -> Maybe [LispVal] -> IOThrowsError LispVal)
                        -> m LispVal
makeHVarargs = makeHFunc . Just . showVal

-- |Validate formal function parameters.
validateFuncParams :: [LispVal] -> Maybe Integer -> IOThrowsError Bool
--validateFuncParams [Atom _] _ = return True
validateFuncParams ps (Just n) = do
  if length ps /= fromInteger n
     then throwError $ NumArgs (Just n) ps
     else validateFuncParams ps Nothing
validateFuncParams ps Nothing = do
  let syms = filter filterArgs ps
  if (length syms) /= (length ps)
     then throwError $ Default $ 
             "Invalid lambda parameter(s): " ++ show (List ps)
     else do
         let strs = DL.sort $ map (\ (Atom a) -> a) ps
         case dupe strs of
            Just d -> throwError $ Default $ 
                         "Duplicate lambda parameter " ++ d
            _ -> return True
 where
  filterArgs (Atom _) = True
  filterArgs _ = False

  dupe (a : b : rest)
    | a == b = Just a
    | otherwise = dupe (b : rest)
  dupe _ = Nothing


loadCamFrame :: (Mat ('S [height, width]) ('S 3) ('S Word8)) -> IO ()
-- A failed ROI or a not-yet-available frame can be an empty Mat. Do not
-- destructure its shape or read its data until a usable 2D image exists.
loadCamFrame img =
  case miShape (matInfo img) of
    [h, w] | h > 0 && w > 0 ->
      withMatData (matFlip img FlipVertically) $ \_ ptr -> do
        -- Live textures use GL_LINEAR, which samples level zero only. Building
        -- mipmaps every frame wastes CPU, especially with Mesa llvmpipe.
        glTexImage2D GL_TEXTURE_2D 0 GL_RGB w h 0 GL_RGB GL_UNSIGNED_BYTE (castPtr ptr)
    _ -> return ()


renderImage :: FilePath -> Mat ('S [height, width]) ('S 3) ('S Word8) -> IO ()
renderImage fp img = do
  let img2 = exceptError $ cvtColor rgb bgr img
      bs = exceptError $ imencode (OutputPng defaultPngParams) img2
  B.writeFile dest bs
    where
      dest = mkDestPath fp


mkDestPath :: FilePath -> FilePath
mkDestPath fp = "1/" <> fp


getImg :: String -> Mat ('S ['D, 'D]) ('S 3) ('S Word8)
getImg img = exceptError $ coerceMat $ unsafePerformIO $
             imdecode ImreadUnchanged <$> B.readFile ("/home/test/Downloads/LearnOpenGL.hs/GettingStarted/Camera/1/" ++ img)


obtainImage :: String -> Mat ('S ['D, 'D]) ('S 3) ('S Word8)
obtainImage img = exceptError $ coerceMat $ unsafePerformIO $ imdecode ImreadUnchanged <$> B.readFile source
  where
    source = mkDestPath img


saveImage :: FilePath -> Mat ('S [height, width]) ('S 3) ('S Word8) -> IO ()
saveImage fp img = do
  let img2 = exceptError $ cvtColor rgb bgr img
      bs = exceptError $ imencode (OutputPng defaultPngParams) img2
  B.writeFile fp bs


