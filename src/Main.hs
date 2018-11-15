{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}

module Main where

import Control.Exception (finally)
import Control.Monad (forever, join)
import Data.Either (either)
import Data.Foldable (traverse_)
import GHC.Generics
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
import qualified Data.ByteString.Char8          as C8
import qualified Data.Text.Encoding             as Enc
import qualified Data.Aeson                     as A
import qualified Network.URI                    as URI
import qualified Data.Map                       as Map

data Player = Player { playerId           :: T.Text
                     , playerName         :: T.Text
                     , playerSelectedCard :: Maybe Card 
                     }
  deriving (Show, Generic)

instance A.ToJSON Player where
  toEncoding = A.genericToEncoding A.defaultOptions  

instance A.FromJSON Player

type Card = Int

type PlayerId = T.Text

mkPlayer :: PlayerId -> T.Text -> Player
mkPlayer pId name = Player {  playerId           = pId
                            , playerName         = name
                            , playerSelectedCard = Nothing }

type Game = Map.Map PlayerId PlayerConnection

type PlayerConnection = (WS.Connection, Player)

data IncomingMessage = 
    PlayerConnected T.Text 
  | PlayersRequest 
  | PlayerSelectedCard Card 
  deriving (Show)

data OutgoingMessage = 
    AllPlayers [Player]
  | NewPlayer Player
  deriving (Show)

toJson :: A.ToJSON a => a -> T.Text
toJson = Enc.decodeUtf8 . BS.toStrict . A.encode

convertMessage :: OutgoingMessage -> T.Text
convertMessage (NewPlayer player) = "PLAYERCONNECTED:" <> toJson player
convertMessage (AllPlayers players) = "PLAYERS:" <> toJson players

main :: IO ()
main = TVar.newTVarIO Map.empty >>= W.run 8080 . app

app :: TVar.TVar Game -> WAI.Application
app conns = WWS.websocketsOr WSC.defaultConnectionOptions wsApp backupApp
  where
    wsApp :: WS.ServerApp
    wsApp pending_conn@(WSC.PendingConnection _ req _ _) = do      
      let uri = URI.parseURI (show . WS.requestPath $ req)      
      case uri of
        Nothing -> do
          _ <- WSC.rejectRequest pending_conn "Not a valid url in request"
          return ()
        Just uri' ->
          case getUserId uri' of
            Nothing -> do
              _ <- WSC.rejectRequest pending_conn "User ID not specified"
              return ()
            Just pId -> do
              conn <- WSC.acceptRequest pending_conn
              putStrLn "Connected"
              WS.forkPingThread conn 30
              WS.sendTextData conn ("Hello, client!" :: T.Text)
              playerConnected (pId, conn) pId conns
              finally (processMessages (pId, conn) conns) (onDisconnect pId conns)      
    backupApp :: WAI.Application
    backupApp _ respond = respond $ WAI.responseLBS HTTP.status400 [] "Not a websocket request"
    getUserId :: URI.URI -> Maybe T.Text
    getUserId = fmap Enc.decodeUtf8 
              . join 
              . Map.lookup "uid" 
              . Map.fromList 
              . HTTP.parseQuery 
              . C8.pack 
              . URI.uriQuery

processMessages :: (PlayerId, WS.Connection) -> TVar.TVar Game -> IO ()
processMessages (pId, conn) conns = 
  forever $ 
    P.parseOnly convert . getMessageText <$> WS.receiveDataMessage conn >>=
      either  (\_ -> return ()) 
              (\case
                  PlayerConnected name -> playerConnected (pId, conn) name conns
                  PlayersRequest -> TVar.readTVarIO conns >>= sendAllPlayersBut conn pId
                  PlayerSelectedCard card -> STM.atomically $ selectCard card pId conns)

playerConnected :: (PlayerId, WS.Connection) -> T.Text -> TVar.TVar Game -> IO ()
playerConnected (pId, conn) name conns = do
  let player = mkPlayer pId name
  STM.atomically $ TVar.modifyTVar conns $ Map.insert pId (conn, player)
  conns' <- TVar.readTVarIO conns
  broadcastToAllBut pId (convertMessage $ NewPlayer player) conns'
  sendAllPlayersBut conn pId conns'
                  
getAllPlayersBut :: PlayerId -> Game -> [Player]
getAllPlayersBut pId = 
  fmap (\(_, p) -> p { playerSelectedCard = Nothing}) . Map.elems . Map.filterWithKey (\i' _ -> pId /= i') 

getMessageText :: WS.DataMessage -> T.Text
getMessageText msg =
  let bin = case msg of
              WS.Text bs _ -> bs
              WS.Binary bs -> bs
  in Enc.decodeUtf8 . BS.toStrict $ bin

sendAllPlayersBut :: WS.Connection -> PlayerId -> Game -> IO ()
sendAllPlayersBut conn pId = WS.sendTextData conn . convertMessage . AllPlayers . getAllPlayersBut pId

broadcastToAll :: T.Text -> Game -> IO ()
broadcastToAll msg = traverse_ (\(conn, _) -> WS.sendTextData conn msg)

broadcastToAllBut :: PlayerId -> T.Text -> Game -> IO ()
broadcastToAllBut pId msg game = 
  broadcastToAll msg (Map.filterWithKey (\i' _ -> pId /= i') game)

onDisconnect :: PlayerId -> TVar.TVar Game -> IO ()
onDisconnect pId conns = do
  STM.atomically $ TVar.modifyTVar conns (Map.delete pId)
  putStrLn "Disconnect"
  return ()

selectCard :: Card -> PlayerId -> TVar.TVar Game -> STM.STM ()
selectCard card pId conns = do
  conns' <- TVar.readTVar conns
  let adjusted = Map.adjust (\(c, p) -> (c, p { playerSelectedCard = Just card })) pId conns'
  TVar.writeTVar conns adjusted

convert :: P.Parser IncomingMessage
convert = P.choice [ playerConnectedParser
                   , playersRequestParser
                   , playerSelectedCardParser]

playerConnectedParser :: P.Parser IncomingMessage
playerConnectedParser = do
  _ <- P.string "PLAYERCONNECTED"
  _ <- P.char ':'
  PlayerConnected <$> P.takeText

playersRequestParser :: P.Parser IncomingMessage
playersRequestParser = do
  _ <- P.string "PLAYERS"
  return PlayersRequest

playerSelectedCardParser :: P.Parser IncomingMessage
playerSelectedCardParser = do
  _ <- P.string "SELECTCARD"
  _ <- P.char ':'
  PlayerSelectedCard <$> P.decimal


