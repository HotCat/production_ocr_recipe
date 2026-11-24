{-# LANGUAGE OverloadedStrings #-}
module EngravingCompare where

import Control.Concurrent.Async (Async, async, poll)
import qualified Control.Exception as E
import Data.Char (isSpace)
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.Text as T

-- Preserve Chinese, Latin case, digits and punctuation. OCR layout whitespace
-- and the two common colon widths do not change the intended engraving.
normalizeEngraving :: String -> String
normalizeEngraving = map colon . filter (not . isSpace)
  where colon '：' = ':'
        colon c = c

data ComparisonResult = ComparisonResult
  { expectedText :: String
  , recognizedText :: String
  , comparisonPassed :: Bool
  , comparisonDetail :: String
  } deriving (Eq, Show, Read)

compareEngraving :: String -> Either String String -> ComparisonResult
compareEngraving expected recognized
  | null (normalizeEngraving expected) = result "" False "未设置预设文字"
  | otherwise = case recognized of
      Left failure -> result "" False ("PaddleOCR: " ++ failure)
      Right raw
        | null (normalizeEngraving raw) -> result raw False "未识别到刻字"
        | normalizeEngraving expected `isInfixOf` normalizeEngraving raw -> result raw True "识别刻字包含预设文字"
        | otherwise -> result raw False "识别刻字未包含预设文字"
  where result raw passed detail = ComparisonResult expected raw passed detail

inspectEngravingWith :: IO String -> String -> IO ComparisonResult
inspectEngravingWith recognize expected
  | null (normalizeEngraving expected) = pure (compareEngraving expected (Right ""))
  | otherwise = do
      outcome <- E.catch (Right <$> recognize) $ \failure ->
        case E.fromException failure :: Maybe E.AsyncException of
          Just _ -> E.throwIO (failure :: E.SomeException)
          Nothing -> pure (Left (E.displayException failure))
      pure (compareEngraving expected outcome)

formatComparison :: ComparisonResult -> String
formatComparison result = (if comparisonPassed result then "OK " else "NG ") ++
  comparisonDetail result ++ " 预设=" ++ schemeString (expectedText result) ++
  " 识别=" ++ schemeString (recognizedText result) ++ "\n"

-- Encode literal Unicode for husk-scheme instead of Haskell's numeric escapes.
schemeString :: String -> String
schemeString value = '"' : concatMap escape value ++ "\""
  where escape '"' = "\\\""
        escape '\\' = "\\\\"
        escape '\n' = "\\n"
        escape '\r' = "\\r"
        escape '\t' = "\\t"
        escape c = [c]

data ComparisonRuntime = ComparisonRuntime
  { comparisonPreset :: IORef T.Text
  , comparisonSettings :: IORef (Maybe (T.Text, Int))
  , comparisonRevision :: IORef Integer
  , comparisonPending :: IORef (Maybe (Integer, Bool, Async ComparisonResult))
  , comparisonTriggerHeld :: IORef Bool
  , comparisonLastResult :: IORef (Maybe ComparisonResult)
  }

data CompletedInspection = InspectionCompleted Bool ComparisonResult | InspectionDiscarded Bool ComparisonResult
  deriving (Eq, Show)

newComparisonRuntime :: IO ComparisonRuntime
newComparisonRuntime = ComparisonRuntime <$> newIORef "客服电话：96008" <*> newIORef Nothing
  <*> newIORef 0 <*> newIORef Nothing <*> newIORef False <*> newIORef Nothing

-- Changing profiles/preset invalidates a pending result without blocking the UI.
syncComparisonSettings :: ComparisonRuntime -> Int -> IO ()
syncComparisonSettings runtime profile = do
  current <- readIORef (comparisonPreset runtime)
  previous <- readIORef (comparisonSettings runtime)
  if previous == Just (current, profile) then pure () else do
    writeIORef (comparisonSettings runtime) (Just (current, profile))
    modifyIORef' (comparisonRevision runtime) (+1)
    writeIORef (comparisonLastResult runtime) Nothing

triggerRising :: ComparisonRuntime -> Bool -> IO Bool
triggerRising runtime triggered = atomicModifyIORef' (comparisonTriggerHeld runtime) $ \previous ->
  (triggered, triggered && not previous)

queueComparison :: ComparisonRuntime -> Bool -> IO String -> IO Bool
queueComparison runtime production recognize = do
  pending <- readIORef (comparisonPending runtime)
  case pending of
    Just _ -> pure False
    Nothing -> do
      expected <- T.unpack <$> readIORef (comparisonPreset runtime)
      revision <- readIORef (comparisonRevision runtime)
      task <- async (inspectEngravingWith recognize expected)
      writeIORef (comparisonPending runtime) (Just (revision, production, task))
      pure True

pollComparison :: ComparisonRuntime -> IO (Maybe CompletedInspection)
pollComparison runtime = do
  pending <- readIORef (comparisonPending runtime)
  case pending of
    Nothing -> pure Nothing
    Just (revision, production, task) -> do
      outcome <- poll task
      case outcome of
        Nothing -> pure Nothing
        Just response -> do
          writeIORef (comparisonPending runtime) Nothing
          currentRevision <- readIORef (comparisonRevision runtime)
          let result = case response of
                Right value -> value
                Left failure -> compareEngraving "" (Left (E.displayException failure))
          if revision /= currentRevision then pure (Just (InspectionDiscarded production result)) else do
            writeIORef (comparisonLastResult runtime) (Just result)
            pure (Just (InspectionCompleted production result))
