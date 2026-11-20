{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- Each production verdict is durable before its corresponding PLC output.
-- The event and clock watermark commit atomically across attached SQLite files
-- using rollback journals (not WAL). The UI may read them while production runs.
module ProductionLog
  ( ProductionEvent(..), productionEvent, initializeProductionLog, recordProduction
  , rememberObservation, readObservation
  ) where

import Control.Exception (bracket, mask, onException)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import System.Posix.IO (openFd, closeFd, defaultFileFlags, OpenMode(ReadWrite), LockRequest(WriteLock), waitToSetLock)
import System.IO (SeekMode(AbsoluteSeek))
import qualified ProductionDebug as PD
import Control.Monad (unless, when, void)
import Data.Int (Int64)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import qualified Data.Text as T
import Data.Time
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Database.SQLite.Simple
import Language.Haskell.TH.Syntax (addDependentFile, runIO)
import Language.Haskell.TH (stringE)
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)

-- Serial observations are shared between the OCR stage and the final verdict
-- stage. Clearing at the start of a cycle prevents an NG from reusing old text.
{-# NOINLINE observations #-}
observations :: IORef (Map.Map String String)
observations = unsafePerformIO (newIORef Map.empty)

rememberObservation :: String -> String -> IO ()
rememberObservation key value = atomicModifyIORef' observations (\m -> (Map.insert key value m, ()))

readObservation :: String -> IO String
readObservation key = Map.findWithDefault "" key <$> readIORef observations

data ProductionEvent = ProductionEvent
  { eventApp :: String, eventPassed :: Bool, eventBarcode :: String
  , eventPackagingBarcode :: String, eventSerial :: String, eventDetected :: String
  , eventPreset :: String, eventBank :: String, eventBankIndex :: Maybe Int
  , eventBankSerialLength :: Maybe Int, eventGuard :: Maybe Bool
  , eventReverse :: Maybe Bool, eventPackagingGuard :: Maybe Bool
  , eventReason :: String
  } deriving (Show)

productionEvent :: String -> Bool -> ProductionEvent
productionEvent app passed = ProductionEvent app passed "" "" "" "" "" "" Nothing Nothing Nothing Nothing Nothing ""

eventSchema, clockSchema :: Query
eventSchema = fromString $(do
  let path = "../../shared/production-log/events.sql"
  addDependentFile path
  runIO (readFile path) >>= stringE)
clockSchema = fromString $(do
  let path = "../../shared/production-log/clock.sql"
  addDependentFile path
  runIO (readFile path) >>= stringE)

clockFloor :: Int64
clockFloor = read $(do
  let path = "../../shared/production-log/clock-floor-us.txt"
  addDependentFile path
  runIO (readFile path) >>= stringE)

logDirectory :: IO FilePath
logDirectory = do
  override <- lookupEnv "OCR_PRODUCTION_LOG_DIR"
  case override of
    Just directory | not (null directory) -> pure directory
    _ -> do
      home <- getHomeDirectory
      dataHome <- fromMaybe (home </> ".local/share") <$> lookupEnv "XDG_DATA_HOME"
      pure (dataHome </> "production-ocr/production-logs")

-- All five Haskell clients share an attached clock database. Serialize their
-- connection setup/migration and short write transactions in a consistent order
-- to avoid schema-lock deadlocks between concurrent SQLite ATTACH operations.
-- POSIX releases this advisory lock on close/crash; the file is never deleted.
-- MVar also covers threads in one process (fcntl locks are process-scoped).
{-# NOINLINE writerMutex #-}
writerMutex :: MVar ()
writerMutex = unsafePerformIO (newMVar ())

withWriterLock :: FilePath -> IO a -> IO a
withWriterLock directory action = withMVar writerMutex $ \_ ->
  bracket (openFd (directory </> "writer.lock") ReadWrite (Just 0o600) defaultFileFlags) closeFd $ \fd -> do
    waitToSetLock fd (WriteLock, AbsoluteSeek, 0, 0)
    action

immediate :: Connection -> IO a -> IO a
immediate connection action = mask $ \restore -> do
  execute_ connection "BEGIN IMMEDIATE"
  result <- restore action `onException` execute_ connection "ROLLBACK"
  execute_ connection "COMMIT" `onException` execute_ connection "ROLLBACK"
  pure result

prepareClock :: FilePath -> IO ()
prepareClock directory = bracket (open (directory </> "clock.sqlite3")) close $ \connection -> do
  execute_ connection "PRAGMA busy_timeout=10000"
  execute_ connection "PRAGMA synchronous=FULL"
  immediate connection $ do
    tables <- query_ connection "SELECT name FROM sqlite_master WHERE type='table' AND name='clock_state'" :: IO [Only String]
    if null tables then do
      execute_ connection clockSchema
      execute connection "INSERT INTO clock_state VALUES (1, ?, NULL)" (Only clockFloor)
    else do
      rows <- query_ connection "SELECT high_water_us FROM clock_state WHERE id=1" :: IO [Only Int64]
      when (null rows) $ ioError (userError "生产时间记录缺失，请恢复数据库备份")

withLog :: String -> (Connection -> IO a) -> IO a
withLog app action = do
  unless (app `elem` ["Barcode+Sequence", "Barcode+Sequence+Barcode", "Barcode+Sequence+Engraving", "Engraving+Sequence", "Engraving+Compare"]) $
    ioError (userError "Unknown production application")
  directory <- logDirectory
  createDirectoryIfMissing True directory
  withWriterLock directory $ do
    prepareClock directory
    bracket (open (directory </> app ++ ".sqlite3")) close $ \connection -> do
      execute_ connection "PRAGMA busy_timeout=10000"
      execute_ connection "PRAGMA synchronous=FULL"
      immediate connection $ do
        execute_ connection eventSchema
        columns <- query_ connection "SELECT name FROM pragma_table_info('production_events') WHERE name='debug_mode'" :: IO [Only String]
        when (null columns) $
          execute_ connection "ALTER TABLE production_events ADD COLUMN debug_mode INTEGER NOT NULL DEFAULT 0 CHECK(debug_mode IN (0,1))"
        execute_ connection "CREATE INDEX IF NOT EXISTS production_events_date ON production_events(local_date, occurred_at_us, id)"
      execute connection "ATTACH DATABASE ? AS guard" (Only (directory </> "clock.sqlite3"))
      action connection

checkedTime :: Connection -> IO UTCTime
checkedTime connection = do
  [Only latest] <- query_ connection "SELECT high_water_us FROM guard.clock_state WHERE id=1" :: IO [Only Int64]
  now <- getCurrentTime
  let micros = floor (utcTimeToPOSIXSeconds now * 1000000) :: Int64
  when (micros < max latest clockFloor) $
    ioError (userError "系统时间早于上次生产/启动时间，已停止生产。请校准 BIOS 和系统日期时间后重新启动。")
  execute connection "UPDATE guard.clock_state SET high_water_us=? WHERE id=1" (Only micros)
  pure now

initializeProductionLog :: String -> IO ()
initializeProductionLog app = withLog app $ \connection -> immediate connection (void (checkedTime connection))

recordProduction :: ProductionEvent -> IO ()
recordProduction event = withLog (eventApp event) $ \connection -> immediate connection $ do
  now <- checkedTime connection
  zone <- getCurrentTimeZone
  let micros = floor (utcTimeToPOSIXSeconds now * 1000000) :: Int64
      local = utcToZonedTime zone now
      txt = SQLText . T.pack
      optionalBoolean = maybe SQLNull (SQLInteger . (\b -> if b then 1 else 0))
      optionalInt = maybe SQLNull (SQLInteger . fromIntegral)
      fields = [txt (eventApp event), SQLInteger micros,
        txt (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" now),
        txt (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" local),
        txt (formatTime defaultTimeLocale "%Y-%m-%d" local),
        txt (if eventPassed event then "OK" else "NG"),
        txt (eventBarcode event), txt (eventPackagingBarcode event), txt (eventSerial event),
        txt (eventDetected event), txt (eventPreset event), txt (eventBank event),
        optionalInt (eventBankIndex event), optionalInt (eventBankSerialLength event),
        optionalBoolean (eventGuard event), optionalBoolean (eventReverse event),
        optionalBoolean (eventPackagingGuard event), SQLInteger (if PD.debugMode then 1 else 0), txt (eventReason event)]
  execute connection "INSERT INTO production_events(app, occurred_at_us, timestamp_utc, timestamp_local, local_date, result, barcode, packaging_barcode, serial_number, detected_text, preset_text, bank, bank_index, bank_serial_length, integrity_guard, reverse, packaging_integrity_guard, debug_mode, reason) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)" fields
  execute connection "UPDATE guard.clock_state SET last_production_us=? WHERE id=1" (Only micros)
