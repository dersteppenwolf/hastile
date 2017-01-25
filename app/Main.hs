{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Exception.Base
import           Control.Monad.IO.Class
import           Data.Aeson
import qualified Data.ByteString.Lazy.Char8  as BSL
import           Data.Foldable
import           Data.Map
import           Data.Maybe                  (fromMaybe)
import           Data.Monoid
import           Data.Text
import           Data.Text.Encoding
import           Data.Time
import           GHC.Conc
import           Hasql.Pool                  as P
import           Network.Wai
import qualified Network.Wai.Handler.Warp    as Warp
import           Network.Wai.Middleware.Cors
import           Options.Generic
import           Servant
import           STMContainers.Map           as STM
import           System.Exit

import           Lib
import           Types

main :: IO ()
main = getRecord "hastile" >>= doIt

doIt :: CmdLine -> IO ()
doIt cmdLine = do
  startTime <- getCurrentTime
  configBs <- BSL.readFile $ configFile cmdLine
  case eitherDecode configBs of
    Right config -> doItWithConfig config startTime
    Left e -> do
      putStrLn $ "In file: " <> configFile cmdLine <> "\nError: " <> e
      exitWith (ExitFailure 2)

doItWithConfig :: Config -> UTCTime -> IO ()
doItWithConfig config startTime = do
      let layers = _configLayers config
      layers' <- liftIO $ atomically STM.new :: IO (STM.Map Text Layer)
      forM_ (Data.Map.toList layers) $ \k -> atomically $ STM.insert (snd k) (fst k) layers'
      let startTime' = formatTime defaultTimeLocale rfc822DateFormat startTime
          startTime'' = dropEnd 3 (pack startTime') <> "GMT"
          pgPoolSize' = fromMaybe 10 $ _configPgPoolSize config
          pgTimeout' = fromMaybe 1 $ _configPgTimeout config
          pluginDir' = fromMaybe "/usr/local/lib/mapnik/input" $ _configMapnikInputPlugins config
          port' = fromMaybe 8080 $ _configPort config
        in bracket (P.acquire (pgPoolSize', pgTimeout', encodeUtf8 $ _configPgConnection config))
                P.release $
                  \p -> getWarp port' . serve api $ hastileService (ServerState p pluginDir' (unpack startTime'') layers')
      pure ()

getWarp :: Warp.Port -> Network.Wai.Application -> IO ()
getWarp port' = Warp.run port' . cors (const $ Just policy)
           where
             policy = simpleCorsResourcePolicy { corsRequestHeaders = ["Content-Type"] }
