{-# LANGUAGE NoImplicitPrelude #-}

module NetNode (workers) where

import           RON.Prelude

import           Control.Concurrent.Async (concurrently_, forConcurrently_)
import           Control.Concurrent.STM (atomically, readTChan)
import           Control.Monad (forever)
import           Data.Aeson (FromJSON, ToJSON, (.:), (.=), (<?>))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.Text.Lazy.Encoding as TextL
import           Debug.Pretty.Simple (pTraceM)
import qualified Network.WebSockets as WS
import qualified RON.Store as Store
import qualified RON.Store.Sqlite as Store
import           RON.Text.Parse (parseOpenFrame, parseUuid)
import           RON.Text.Serialize (serializeUuid)
import           RON.Text.Serialize.Experimental (serializeOpenFrame)
import           RON.Types.Experimental (Patch (..))

import           Fork (forkLinked)
import           Options (NodeOptions (..))

workers :: Store.Handle -> NodeOptions -> IO ()
workers db NodeOptions{listenHost, listenPorts, peers} =
  concurrently_
    (forConcurrently_ listenPorts \port -> do
      pTraceM $ "Listening at [" <> show listenHost <> "]:" <> show port
      WS.runServer (show listenHost) port server)
    (forConcurrently_ peers \port -> do
      pTraceM $ "Connecting to [::1]:" <> show port
      WS.runClient "::1" port "/" client)
  where

    server pending = do
      conn <- WS.acceptRequest pending
      pTraceM $ "Accepted connection from " <> show (WS.pendingRequest pending)
      dialog db conn

    client = dialog db

dialog :: Store.Handle -> WS.Connection -> IO ()
dialog db conn = do
  -- first, advertise own database state
  do
    patches <- Store.runStore db Store.loadLog
    case patches of
      [] ->
        pTraceM "No log for the chatroom"
      _ : _ -> do
        pTraceM $ "Log for the chatroom: " <> show (length patches)
        for_ patches \patch -> do
          pTraceM $ "Send initial patch " <> show patch
          WS.sendBinaryData conn $ Aeson.encode $ NetPatch patch

  -- send
  forkLinked do
    onUpdate <- Store.fetchUpdates db
    forever $ do
      patch <- atomically $ readTChan onUpdate
      pTraceM $ "Send new patch " <> show patch
      WS.sendBinaryData conn $ Aeson.encode $ NetPatch patch

  -- receive
  WS.withPingThread conn 30 (pure ()) $
    forever do
      messageData <- WS.receiveData conn
      case Aeson.eitherDecode messageData of
        Left e ->
          error $
            "NetNode.dialog: Aeson.eitherDecode: " <> e
            <> ", messageData = " <> show messageData
        Right netMessage -> do
          pTraceM $ "Received " <> show netMessage
          case netMessage of
            NetPatch patch -> Store.runStore db $ Store.appendPatch patch

newtype NetMessage = NetPatch Patch
  deriving Show

instance ToJSON NetMessage where
  toJSON = \case
    NetPatch Patch{object, log} ->
      Aeson.object
        [ "Type"   .= ("NetPatch" :: Text)
        , "object" .= TextL.decodeUtf8 (serializeUuid object)
        , "log"    .= TextL.decodeUtf8 (serializeOpenFrame $ toList log)
        ]

instance FromJSON NetMessage where
  parseJSON =
    Aeson.withObject "NetMessage" \o -> do
      type_ <- o .: "Type"
      case type_ of
        "NetPatch" -> do
          objectText <- TextL.encodeUtf8 <$> o .: "object"
          object <-
            either fail pure (parseUuid objectText) <?> Aeson.Key "object"
          logText <- TextL.encodeUtf8 <$> o .: "log"
          logList <-
            either fail pure (parseOpenFrame logText) <?> Aeson.Key "log"
          log <- maybe (fail "empty log") pure $ nonEmpty logList
          pure $ NetPatch Patch{object, log}
        _ -> fail $ "unknown Type " <> type_
