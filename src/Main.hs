{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Main where

import Control.Exception (finally)
import Control.Monad (forever, unless)
import Data.Either (either)
import qualified Data.Text                      as T
import qualified Network.Wai                    as WAI
import qualified Network.Wai.Handler.Warp       as W
import qualified Network.Wai.Handler.WebSockets as WWS
import qualified Network.WebSockets.Connection  as WSC
import qualified Network.WebSockets             as WS
import qualified Network.HTTP.Types             as HTTP
import qualified Control.Monad.STM              as STM
import qualified Control.Concurrent.STM.TVar    as TVar
import qualified Data.Attoparsec.Text           as P
import qualified Data.ByteString.Lazy           as BS
import qualified Data.Text.Encoding             as Enc
import qualified Data.Aeson                     as A
import GHC.Generics

newtype Player = Player { playerName :: T.Text }
  deriving (Show, Generic)

instance A.ToJSON Player where
  toEncoding = A.genericToEncoding A.defaultOptions  

instance A.FromJSON Player

mkPlayer :: T.Text -> Player
mkPlayer name = Player { playerName = name }

type PlayerConnection = (Int, WS.Connection, Player)

data IncomingMessage = PlayerConnected T.Text 
                     | PlayersRequest  
  deriving (Show)

data OutgoingMessage = AllPlayers [Player]
                     | NewPlayer Player
  deriving (Show)

toJson :: A.ToJSON a => a -> T.Text
toJson = Enc.decodeUtf8 . BS.toStrict . A.encode

convertMessage :: OutgoingMessage -> T.Text
convertMessage (NewPlayer player) = "PLAYERCONNECTED:" <> toJson player
convertMessage (AllPlayers players) = "PLAYERS:" <> toJson players

main :: IO ()
main = do
  conns <- TVar.newTVarIO []
  nextId <- TVar.newTVarIO 1
  W.run 8080 (app conns nextId)

app :: TVar.TVar [PlayerConnection] -> TVar.TVar Int -> WAI.Application
app conns nextId = WWS.websocketsOr WSC.defaultConnectionOptions wsApp backupApp
  where
    wsApp :: WS.ServerApp
    wsApp pending_conn = do
      conn <- WSC.acceptRequest pending_conn
      putStrLn "Connected"
      connId <- STM.atomically $ do
        nextId' <- TVar.readTVar nextId
        TVar.writeTVar nextId (nextId' + 1)
        return nextId'        
      WS.forkPingThread conn 30
      WS.sendTextData conn ("Hello, client!" :: T.Text)
      finally (processMessages (connId, conn) conns) (onDisconnect connId conns)      
    backupApp :: WAI.Application
    backupApp _ respond = respond $ WAI.responseLBS HTTP.status400 [] "Not a websocket request"

processMessages :: (Int, WS.Connection) -> TVar.TVar [PlayerConnection] -> IO ()
processMessages (connId, conn) conns = 
  forever $ do
    gameMsg <- P.parseOnly convert . getMessageText <$> WS.receiveDataMessage conn
    either (\_ -> return ()) (\msg ->
      case msg of
        PlayerConnected name -> do
          let player = mkPlayer name
          STM.atomically $ TVar.modifyTVar conns ((:) (connId, conn, player))
          conns' <- TVar.readTVarIO conns
          broadcastToAllBut connId (convertMessage $ NewPlayer player) conns'
          sendAllPlayersBut conn connId conns'
          return ()
        PlayersRequest -> TVar.readTVarIO conns >>= sendAllPlayersBut conn connId
      ) gameMsg

getAllPlayersBut :: Int -> [PlayerConnection] -> [Player]
getAllPlayersBut i = 
  fmap (\(_, _, p) -> p) . filter (\(i', _, _) -> i' /= i)

getMessageText :: WS.DataMessage -> T.Text
getMessageText msg =
  let bin = case msg of
              WS.Text bs _ -> bs
              WS.Binary bs -> bs
  in Enc.decodeUtf8 . BS.toStrict $ bin

sendAllPlayersBut :: WS.Connection -> Int -> [PlayerConnection] -> IO ()
sendAllPlayersBut conn connId = WS.sendTextData conn . convertMessage . AllPlayers . getAllPlayersBut connId


broadcastToAll :: T.Text -> [PlayerConnection] -> IO ()
broadcastToAll msg = 
  mapM_ (\(i, conn, _) -> do
    putStrLn $ "Sending message to: " <> show i
    WS.sendTextData conn msg)

broadcastToAllBut :: Int -> T.Text -> [PlayerConnection] -> IO ()
broadcastToAllBut i msg = 
  mapM_ (\(i', conn, _) -> unless (i == i') $ WS.sendTextData conn msg)  

onDisconnect :: Int -> TVar.TVar [PlayerConnection] -> IO ()
onDisconnect conn conns = do
  STM.atomically $ TVar.modifyTVar conns (filter (\(i, _, _) -> (i /= conn)))
  putStrLn "Disconnect"
  return ()

convert :: P.Parser IncomingMessage
convert = P.choice [playerConnectedParser, playersRequestParser]

playerConnectedParser :: P.Parser IncomingMessage
playerConnectedParser = do
  _ <- P.string "PLAYERCONNECTED"
  _ <- P.char ':'
  PlayerConnected <$> P.takeText

playersRequestParser :: P.Parser IncomingMessage
playersRequestParser = do
  _ <- P.string "PLAYERS"
  return PlayersRequest


