{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Exception (finally)
import Control.Monad (forever)
import qualified Data.Text                      as T
import qualified Network.Wai                    as WAI
import qualified Network.Wai.Handler.Warp       as W
import qualified Network.Wai.Handler.WebSockets as WWS
import qualified Network.WebSockets.Connection  as WSC
import qualified Network.WebSockets             as WS
import qualified Network.HTTP.Types             as HTTP
import qualified Control.Monad.STM              as STM
import qualified Control.Concurrent.STM.TVar    as TVar

main :: IO ()
main = do
  conns <- TVar.newTVarIO []
  nextId <- TVar.newTVarIO 1
  W.run 8080 (app conns nextId)

app :: TVar.TVar [(Int, WS.Connection)] -> TVar.TVar Int -> WAI.Application
app conns nextId = WWS.websocketsOr WSC.defaultConnectionOptions wsApp backupApp
  where
    wsApp :: WS.ServerApp
    wsApp pending_conn = do
      conn <- WSC.acceptRequest pending_conn
      putStrLn "Connected"
      connId <- STM.atomically $ do
        nextId' <- TVar.readTVar nextId
        TVar.writeTVar nextId (nextId' + 1)
        TVar.modifyTVar conns ((:) (nextId', conn))
        return nextId'
        
      WS.forkPingThread conn 30
      WS.sendTextData conn ("Hello, client!" :: T.Text)
      finally (processMessages (connId, conn) conns) (onDisconnect connId conns)      
    backupApp :: WAI.Application
    backupApp _ respond = respond $ WAI.responseLBS HTTP.status400 [] "Not a websocket request"

processMessages :: (Int, WS.Connection) -> TVar.TVar [(Int, WS.Connection)] -> IO ()
processMessages (connId, conn) conns = 
  forever $ do
    msg <- WS.receive conn
    conns' <- TVar.readTVarIO conns
    broadcastToAll "Received" conns'
    --WS.sendTextData conn ("Received" :: T.Text)

broadcastToAll :: T.Text -> [(Int, WS.Connection)] -> IO ()
broadcastToAll msg = 
  mapM_ (\(_, conn) -> WS.sendTextData conn msg)

onDisconnect :: Int -> TVar.TVar [(Int, WS.Connection)] -> IO ()
onDisconnect conn conns = do
  STM.atomically $ TVar.modifyTVar conns (filter ((/= conn) . fst))
  putStrLn "Disconnect"
  return ()