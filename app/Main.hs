{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import qualified Control.Exception.Base            as ControlException
import qualified Control.Monad                     as Monad
import qualified Control.Monad.IO.Class            as MonadIO
import qualified Data.Foldable                     as Foldable
import qualified Data.LruCache.IO                  as LRU
import qualified Data.Map                          as Map
import qualified Data.Text                         as Text
import qualified Data.Text.Encoding                as TextEncoding
import qualified Data.Time                         as Time
import           GHC.Conc
import qualified Hasql.Pool                        as HasqlPool
import qualified Katip
import qualified Network.Wai                       as Wai
import qualified Network.Wai.Handler.Warp          as WaiWarp
import qualified Network.Wai.Middleware.Cors       as WaiCors
import qualified Network.Wai.Middleware.Prometheus as WaiPrometheus
import qualified Options.Generic                   as OptionsGeneric
import qualified Prometheus
import qualified Prometheus.Metric.GHC             as PrometheusGhc
import qualified STMContainers.Map                 as StmMap

import qualified Hastile.Config                    as Config
import qualified Hastile.Server                    as Server
import qualified Hastile.Types.App                 as App
import qualified Hastile.Types.Config              as Config
import qualified Hastile.Types.Layer               as Layer
import qualified Hastile.Types.Logger              as Logger

main :: IO ()
main = OptionsGeneric.getRecord "hastile" >>= doIt

doIt :: Config.CmdLine -> IO ()
doIt cmdLine = do
  let cfgFile = Config.configFile cmdLine
  config <- Config.getConfig cfgFile
  doItWithConfig cfgFile config

doItWithConfig :: FilePath -> Config.Config -> IO ()
doItWithConfig cfgFile config@Config.Config{..} = do
  logEnv <- Logger.logHandler _configAppLog (Katip.Environment _configEnvironment)
  accessLogEnv <- Logger.logHandler _configAccessLog (Katip.Environment _configEnvironment)
  layerMetric <- registerLayerMetric
  newTokenAuthorisationCache <- LRU.newLruHandle _configTokenCacheSize
  layers <- atomically StmMap.new :: IO (StmMap.Map OptionsGeneric.Text Layer.Layer)
  Foldable.forM_ (Map.toList _configLayers) $ \(k, v) -> atomically $ StmMap.insert (Layer.Layer k v) k layers
  let state p = App.ServerState p cfgFile config layers newTokenAuthorisationCache logEnv layerMetric
  ControlException.bracket
    (HasqlPool.acquire (_configPgPoolSize, _configPgTimeout, TextEncoding.encodeUtf8 _configPgConnection))
    (cleanup [logEnv, accessLogEnv])
    (getWarp accessLogEnv _configPort . Server.runServer . state)
  pure ()

cleanup :: [Katip.LogEnv] -> HasqlPool.Pool -> IO ()
cleanup logEnvs pool = do
  _ <- HasqlPool.release pool
  _ <- Monad.mapM_ Katip.closeScribes logEnvs
  pure ()

getWarp :: Katip.LogEnv -> WaiWarp.Port -> Wai.Application -> IO ()
getWarp logEnv port' app = do
  _ <- Prometheus.register PrometheusGhc.ghcMetrics
  let policy = WaiCors.simpleCorsResourcePolicy { WaiCors.corsRequestHeaders = ["Content-Type"] }
      application = WaiCors.cors (const $ Just policy) app
      logging = waiRequestLogger logEnv
      promMiddleware = WaiPrometheus.prometheus $ WaiPrometheus.PrometheusSettings ["metrics"] True True
  WaiWarp.run port' . promMiddleware $ logging application

waiRequestLogger :: Katip.LogEnv -> Wai.Middleware
waiRequestLogger env app req respond =
  app req $ \res -> do
    currentTime <- MonadIO.liftIO Time.getCurrentTime
    Logger.apacheLog env currentTime req res
    respond res

{-# NOINLINE registerLayerMetric #-}
registerLayerMetric :: (MonadIO.MonadIO m) => m (Prometheus.Vector (Text.Text, Text.Text) Prometheus.Counter)
registerLayerMetric = Prometheus.register
            $ Prometheus.vector ("token", "layer")
            $ Prometheus.counter
            $ Prometheus.Info "layers_by_token" "Count of layer views by token."


