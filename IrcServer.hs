module IrcServer (
    IrcServer(..),
    IrcConnection(..),
    connect,
    listen,
    send
) where

import Config

import Prelude hiding ()

import IrcMessage

import Network (connectTo, PortID(PortNumber))

import System.IO (Handle, hSetBuffering, BufferMode(..), hGetLine,
                  mkTextEncoding, hSetEncoding, stdout, hSetNewlineMode,
                  NewlineMode(..), Newline(..))

import Control.Concurrent (forkIO, forkFinally, ThreadId)
import Control.Concurrent.Chan (Chan(..), newChan, writeChan, readChan, getChanContents)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar (TVar(..), newTVar, readTVar, writeTVar)

import Control.Exception (IOException, handle)

import Control.Monad (forever, ap)
import Control.Monad.Reader (ReaderT(..), runReaderT, ask, reader, liftIO)

import Control.Conditional (if', ifM)

data IrcServer = IrcServer {
                    host :: String,
                    port :: Int,
                    ssl :: Bool
                 }

data IrcConnection = IrcConnection {
                        readQ :: Chan Message,
                        sendQ :: Chan Message,
                        connected :: TVar Bool
                     }

connect :: String -> Int -> IO Handle
connect server port = connectTo server portno >>=
                      \h ->
                        mkTextEncoding "UTF-8//IGNORE" >>=
                        hSetEncoding h >>
                        hSetBuffering h NoBuffering >>
                        hSetNewlineMode h nlCRLFMode >>
                        return h
        where
            portno = PortNumber . fromIntegral $ port
            nlCRLFMode = NewlineMode CRLF CRLF

listen :: ReaderT Handle IO IrcConnection
listen = reader (flip (,)) `ap` makeConn >>= \(ic, h) ->
            (loopWithState (connected ic) $ hGetLine h >>=
                                            readOnto (readQ ic)) >>
            (loopWhile (connected ic) $ writeOnto h (sendQ ic)) >>
            return ic
        where
            readOnto :: Chan Message -> String -> IO ()
            readOnto inp st = putStrLn st >>
                              writeChan inp (read st)
            writeOnto :: Handle -> Chan Message -> IO ()
            writeOnto h out = readChan out >>=
                              write h
            makeConn :: ReaderT Handle IO IrcConnection
            makeConn = liftIO newChan >>= \input ->
                       liftIO newChan >>= \output ->
                       liftIO (atomically $ newTVar True) >>= \state ->
                           return (IrcConnection input output state)
            loopWithState :: TVar Bool -> IO a -> ReaderT Handle IO ThreadId
            loopWithState tv io = liftIO $ forkFinally (forever io) (const . atomically $ writeTVar tv False) 
            loopWhile :: TVar Bool -> IO () -> ReaderT Handle IO ThreadId
            loopWhile tv io = liftIO . forkIO . forever $ ifM (atomically $ readTVar tv) io (return ())

send :: Message -> ReaderT Handle IO ()
send msg = ReaderT (flip write msg)

