{-# LANGUAGE OverloadedStrings #-}
module Main where
import EngravingCompare
import RuntimePaths
import Control.Concurrent
import Control.Exception (throwIO, bracket, bracket_)
import Control.Monad
import Data.IORef
import Data.List (isInfixOf)
import Control.Monad.Trans.Except (runExceptT)
import qualified Language.Scheme.Variables as Variables
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Language.Scheme.Core as Scheme
import Language.Scheme.Types (LispVal(..), CtrlHub(..))
import System.Timeout
import System.Directory
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO (openTempFile, hClose, IOMode(..))
import qualified Data.ByteString as B
import qualified Data.Text.Encoding as TE
import System.IO (hPutStr)
import qualified System.IO


assert label passed = unless passed (fail label)
within action = timeout 3000000 action >>= maybe (fail "async test timed out") pure
waitResult runtime = within loop where
  loop = pollComparison runtime >>= maybe (threadDelay 1000 >> loop) pure
passes preset raw = comparisonPassed (compareEngraving preset (Right raw))

main = do
  testPersistence
  forM_ ["客服电话：96008", "客 服 电话 : 96008\n", "客服电话:96008"] $ \raw ->
    assert "Chinese text retained; layout and colon width ignored" (passes "客服电话：96008" raw)
  assert "mixed Chinese, Latin and punctuation preserved" (passes "客服电话：96008 / ABC-01" "客服电话:96008/ABC-01")
  forM_ ["96008", "客服电活：96008", "客服电话：96009", "客服电话：96008额外", "", " \n"] $ \raw ->
    assert ("reject changed/missing/extra characters: " ++ raw) (not (passes "客服电话：96008" raw))
  assert "Latin case is significant" (not (passes "客户 ABC" "客户 abc"))
  assert "punctuation cannot disappear" (not (passes "客服电话：96008" "客服电话96008"))
  assert "empty preset cannot pass" (not (passes " \n" ""))
  assert "same preset may pass repeatedly without increment" (all (passes "客服电话：96008") (replicate 5 "客服电话：96008"))
  failure <- inspectEngravingWith (throwIO (userError "offline")) "客服电话：96008"
  assert "OCR failure rejects" (not (comparisonPassed failure) && "offline" `isInfixOf` comparisonDetail failure)
  called <- newIORef False
  blank <- inspectEngravingWith (writeIORef called True >> pure "wrong") " "
  didCall <- readIORef called
  assert "unset preset skips OCR and rejects" (not didCall && not (comparisonPassed blank))
  putStrLn "PASS: multilingual whole-text comparison, case/punctuation, missing/extra text and no sequence increment"

  -- Roundtrip through the actual Scheme control loader used by GUI profiles.
  env <- Scheme.r5rsEnv
  ref <- newIORef T.empty
  let unusual = "客服电话：96008 ABC \"quoted\" \\ path\n第二行\tEnd"
  refs <- newIORef (Map.singleton "engraving-expected-text" (TextHub1 ref))
  -- evalString supports defining a Scheme value through the interpreter API.
  _ <- Scheme.evalString env ("(define preset " ++ schemeString unusual ++ ")")
  quoted <- Scheme.evalString env "preset"
  assert "Scheme string emits Unicode instead of numeric escapes" ('客' `elem` schemeString unusual)
  -- Install AllConfigs exactly as in Main.
  _ <- runExceptT $ Variables.defineVar env "all-controls-references" (AllConfigs refs)
  _ <- Scheme.evalString env ("(load-system-property all-controls-references \"engraving-expected-text\" " ++ schemeString unusual ++ ")")
  saved <- readIORef ref
  assert ("saved UTF-8 preset roundtrip: " ++ quoted) (saved == T.pack unusual)
  putStrLn "PASS: saved Unicode/quotes/backslashes/newlines load through the real Scheme profile interface"

  runtime <- newComparisonRuntime
  syncComparisonSettings runtime 0
  first <- triggerRising runtime True
  held <- triggerRising runtime True
  _ <- triggerRising runtime False
  next <- triggerRising runtime True
  assert "held PLC trigger starts once; release rearms" (first && not held && next)
  started <- newEmptyMVar
  release <- newEmptyMVar
  let slow = putMVar started () >> takeMVar release >> pure "客服电话：96008"
  queued <- within (queueComparison runtime True slow)
  within (takeMVar started)
  duplicate <- queueComparison runtime True (pure "wrong")
  pending <- pollComparison runtime
  assert "nonblocking and one pending inspection" (queued && not duplicate && pending == Nothing)
  putMVar release ()
  completed <- waitResult runtime
  assert "production context and both texts retained" (completed == InspectionCompleted True (compareEngraving "客服电话：96008" (Right "客服电话：96008")))
  once <- pollComparison runtime
  assert "completion consumed once" (once == Nothing)
  _ <- queueComparison runtime False (pure "客服电话：96008")
  preview <- waitResult runtime
  assert "evaluation distinct from production" (case preview of InspectionCompleted False _ -> True; _ -> False)
  _ <- queueComparison runtime True slow
  within (takeMVar started)
  writeIORef (comparisonPreset runtime) "HELLO"
  syncComparisonSettings runtime 0
  writeIORef (comparisonPreset runtime) "客服电话：96008"
  syncComparisonSettings runtime 0
  putMVar release ()
  stale <- waitResult runtime
  assert "edit-and-revert invalidates old pending result" (stale == InspectionDiscarded True (compareEngraving "客服电话：96008" (Right "客服电话：96008")))
  _ <- queueComparison runtime True slow
  within (takeMVar started)
  syncComparisonSettings runtime 1
  putMVar release ()
  staleProfile <- waitResult runtime
  assert "profile switch invalidates pending result" (staleProfile == InspectionDiscarded True (compareEngraving "客服电话：96008" (Right "客服电话：96008")))
  _ <- queueComparison runtime True (pure "客服电话：96008")
  recovery <- waitResult runtime
  assert "next inspection recovers" (case recovery of InspectionCompleted True result -> comparisonPassed result; _ -> False)
  putStrLn "PASS: async lifecycle, bounded concurrency, trigger latch, single completion and settings invalidation"

-- Exercise the actual Save Parameters disk path and the next startup's Scheme
-- loader with a fresh reference, including saving a non-default profile.
testPersistence = bracket temporaryDirectory removeDirectoryRecursive $ \directory -> do
  let runtime = directory ++ "/runtime"
      savedDirectory = directory ++ "/saved"
  createDirectory runtime
  withSetting "ENGRAVING_COMPARE_RUNTIME_DIR" runtime $
    withSetting "ENGRAVING_COMPARE_CONFIG_DIR" savedDirectory $ do
      fallback <- getStartupProfile
      assert "first startup selects profile 1" (fallback == 0)
      forM_ [(0, "客服电话：96008"), (1, "客户 ABC-12 \"quoted\" \\ path\n第二行"), (2, "客服电话：12345 XYZ")] $ \(profile, preset) -> do
        let file = "config" ++ show (profile + 1) ++ ".scm"
        withRuntimeConfigFile file WriteMode $ \handle ->
          hPutStr handle ("(begin (load-system-property all-controls-references \"engraving-expected-text\" " ++ schemeString preset ++ "))")
        persistRuntimeProfile profile
        bytes <- B.readFile (savedDirectory ++ "/" ++ file)
        assert "preset saved immediately as UTF-8 before GUI exit" (TE.encodeUtf8 (T.pack "客") `B.isInfixOf` bytes)
        -- Simulate loss of all RAM files and a new program startup.
        removeFile (runtime ++ "/" ++ file)
        restoredProfile <- getStartupProfile
        assert "startup selects the last saved profile" (restoredProfile == profile)
        copyFile (savedDirectory ++ "/" ++ file) (runtime ++ "/" ++ file)
        restored <- newIORef T.empty
        refs <- newIORef (Map.singleton "engraving-expected-text" (TextHub1 restored))
        env <- Scheme.r5rsEnv
        _ <- runExceptT $ Variables.defineVar env "all-controls-references" (AllConfigs refs)
        _ <- withRuntimeConfigFile file ReadMode $ \handle -> do
          contents <- System.IO.hGetContents handle
          Scheme.evalString env contents
        value <- readIORef restored
        assert "next startup restores saved preset using actual Scheme loader" (value == T.pack preset)
      B.writeFile (savedDirectory ++ "/startup-profile") (TE.encodeUtf8 "99")
      invalid <- getStartupProfile
      assert "invalid profile falls back to profile 1" (invalid == 0)
  putStrLn "PASS: immediate UTF-8 disk persistence and next-startup preset/profile restore after RAM files disappear"
  where
    temporaryDirectory = do
      (path, handle) <- openTempFile "/tmp" "engraving-preset-save."
      hClose handle
      removeFile path
      createDirectory path
      pure path
    withSetting name value action = do
      previous <- lookupEnv name
      bracket_ (setEnv name value) (maybe (unsetEnv name) (setEnv name) previous) action
