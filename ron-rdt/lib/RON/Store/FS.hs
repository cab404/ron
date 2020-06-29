{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module RON.Store.FS (Handle, newHandle, runStore) where

import           RON.Prelude

import           Data.Bits (shiftL)
import qualified Data.ByteString.Lazy as BSL
import           Data.Foldable (find)
import           Data.String (fromString)
import           Network.Info (MAC (MAC), getNetworkInterfaces, mac)
import           System.Directory (createDirectoryIfMissing, doesDirectoryExist,
                                   doesFileExist, listDirectory, makeAbsolute)
import           System.FilePath ((</>))
import           System.Random.TF (newTFGen)
import           System.Random.TF.Instances (random)

import           RON.Data.Experimental (Rep, ReplicatedObject, replicatedTypeId)
import           RON.Epoch (EpochClock, getCurrentEpochTime, runEpochClock)
import           RON.Error (Error (..), MonadE, errorContext, liftEitherString,
                            tryIO)
import           RON.Event (EpochTime, ReplicaClock, ReplicaId,
                            applicationSpecific, getEventUuid)
import           RON.Store (MonadStore (..))
import           RON.Text.Parse (parseOpenFrame, parseOpenOp)
import           RON.Text.Serialize.Experimental (serializeOpenFrame)
import           RON.Types (ObjectRef (..), Op (..), UUID)
import qualified RON.UUID as UUID

-- | Store handle (uses the “Handle pattern”).
data Handle = Handle
  { clock   :: IORef EpochTime
  , dataDir :: FilePath
  -- fsWatchManager    :: FSNotify.WatchManager,
  -- stopWatching      :: IORef (Maybe StopListening),
  -- onDocumentChanged :: TChan RawDocId,
  -- ^ A channel of changes in the database.
  -- To activate it, call 'startWatching'.
  -- You should NOT read from it directly,
  -- call 'subscribe' to read from derived channel instead.
  , replica :: ReplicaId
  }

newtype Store a = Store (ExceptT Error (ReaderT Handle EpochClock) a)
  deriving
    (Applicative, Functor, Monad, MonadError Error, MonadIO, ReplicaClock)

instance MonadStore Store where
  listObjectsImpl = do
    Handle{dataDir} <- Store ask
    objectDirs <-
      tryIO $ do
        exists <- doesDirectoryExist dataDir
        if exists then listDirectory dataDir else pure []
    traverse uuidFromFileName objectDirs

  appendPatch = appendPatchFS

  loadObjectLog objectId = do
    Handle{dataDir} <- Store ask
    let objectLogsDir = dataDir </> uuidToFileName objectId </> "log"
    objectExists <- tryIO $ doesDirectoryExist objectLogsDir
    if objectExists then do
      patchNames <- tryIO $ listDirectory objectLogsDir
      for patchNames $ \patchName -> do
        let patchFile = objectLogsDir </> patchName
        patchContent <- tryIO $ BSL.readFile patchFile
        liftEitherString $ parseOpenFrame patchContent
    else
      pure []

  openGlobalObject = openGlobalObjectFS

openGlobalObjectFS ::
  forall a. ReplicatedObject a => UUID -> Store (ObjectRef a)
openGlobalObjectFS objectId =
  errorContext ("openGlobalObject " <> show objectId) $ do
    Handle{dataDir} <- Store ask
    let
      objectDir = dataDir </> uuidToFileName objectId
      initFile  = objectDir </> "init"
    initExists <- tryIO $ doesFileExist initFile
    if initExists then do
      -- check type
      initContent <- tryIO $ BSL.readFile initFile
      initOp <- liftEitherString $ parseOpenOp initContent
      when (initOp /= canonicalInitOp) $
        throwError $
        Error
          "Bad init"
          [ fromString $ "got "      <> show initOp
          , fromString $ "expected " <> show canonicalInitOp
          ]
    else do
      -- create
      tryIO $ createDirectoryIfMissing True objectDir
      tryIO $ BSL.writeFile initFile $ serializeOpenFrame [canonicalInitOp]
    pure (ObjectRef objectId)
  where
    canonicalInitOp =
      Op{opId = objectId, refId = replicatedTypeId @(Rep a), payload = []}

appendPatchFS :: UUID -> [Op] -> Store ()
appendPatchFS objectId patch = do
  Handle{dataDir} <- Store ask
  let objectLogsDir = dataDir </> uuidToFileName objectId </> "log"
  tryIO $ createDirectoryIfMissing True objectLogsDir
  patchVersion <- getEventUuid
  let patchFile = objectLogsDir </> uuidToFileName patchVersion
  tryIO $ BSL.writeFile patchFile $ serializeOpenFrame patch

-- | Run a 'Store' action
runStore :: Handle -> Store a -> IO a
runStore h@Handle{replica, clock} (Store action) = do
  res <- runEpochClock replica clock $ (`runReaderT` h) $ runExceptT action
  either throwIO pure res

-- | Create new storage handle.
-- Uses MAC address for replica id or generates a random one.
newHandle :: FilePath -> IO Handle
newHandle hDataDir = do
  macAddress <- getMacAddress
  replicaId  <-
    case macAddress of
      Just macAddress' -> pure macAddress'
      Nothing          -> fst . random <$> newTFGen
  newHandleWithReplicaId hDataDir replicaId

newHandleWithReplicaId :: FilePath -> Word64 -> IO Handle
newHandleWithReplicaId dataDir' replicaId = do
  dataDir <- makeAbsolute dataDir'
  time    <- getCurrentEpochTime
  clock   <- newIORef time
  -- fsWatchManager <- FSNotify.startManager
  -- stopWatching      <- newIORef Nothing
  -- onDocumentChanged <- newBroadcastTChanIO
  let replica = applicationSpecific replicaId
  pure Handle{..}

getMacAddress :: IO (Maybe Word64)
getMacAddress =
  do
    macAddress <- getMac
    pure $ decodeMac <$> macAddress
  where
    getMac = find (/= minBound) . map mac <$> getNetworkInterfaces
    decodeMac (MAC b5 b4 b3 b2 b1 b0)
      = (fromIntegral b5 `shiftL` 40)
      + (fromIntegral b4 `shiftL` 32)
      + (fromIntegral b3 `shiftL` 24)
      + (fromIntegral b2 `shiftL` 16)
      + (fromIntegral b1 `shiftL` 8)
      +  fromIntegral b0

uuidFromFileName :: MonadE m => FilePath -> m UUID
uuidFromFileName =
  maybe (throwError "UUID.decodeBase32: filename is not a valid UUID") pure
  . UUID.decodeBase32

uuidToFileName :: UUID -> FilePath
uuidToFileName = UUID.encodeBase32
