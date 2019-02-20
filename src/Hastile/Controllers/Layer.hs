{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeOperators         #-}

module Hastile.Controllers.Layer where

import           Control.Lens                        ((^.))
import           Control.Monad.Error.Class
import qualified Control.Monad.IO.Class              as MonadIO
import qualified Control.Monad.Logger                as MonadLogger
import qualified Control.Monad.Reader.Class          as ReaderClass
import qualified Data.Aeson                          as Aeson
import qualified Data.Aeson.Encode.Pretty            as AesonPretty
import qualified Data.ByteString                     as ByteString
import qualified Data.ByteString.Lazy.Char8          as ByteStringLazyChar8
import qualified Data.Char                           as Char
import qualified Data.Geometry.GeoJsonStreamingToMvt as GeoJsonStreamingToMvt
import qualified Data.Geometry.Types.Config          as TypesConfig
import qualified Data.Geometry.Types.Geography       as TypesGeography
import qualified Data.Geometry.Types.MvtFeatures     as TypesMvtFeatures
import qualified Data.Geospatial                     as Geospatial
import qualified Data.Map                            as Map
import qualified Data.Text                           as Text
import qualified Data.Text.Encoding                  as TE
import qualified Data.Text.Read                      as DTR
import           Data.Time
import           GHC.Conc
import           ListT
import           Network.HTTP.Types.Header           (hLastModified)
import           Numeric.Natural                     (Natural)
import qualified Servant
import qualified STMContainers.Map                   as STMMap

import qualified Hastile.DB.Layer                    as DBLayer
import qualified Hastile.Lib.Layer                   as LayerLib
import qualified Hastile.Lib.Tile                    as TileLib
import qualified Hastile.Routes                      as Routes
import qualified Hastile.Types.App                   as App
import qualified Hastile.Types.Config                as Config
import qualified Hastile.Types.Layer                 as Layer
import qualified Hastile.Types.Layer.Format          as LayerFormat
import qualified Hastile.Types.Layer.Security        as LayerSecurity

--layerServer :: Servant.ServerT Routes.LayerApi App.ActionHandler
layerServer l = provisionLayer l Servant.:<|> serveLayer l

stmMapToList :: STMMap.Map k v -> STM [(k, v)]
stmMapToList = ListT.fold (\l -> return . (:l)) [] . STMMap.stream

--createNewLayer :: Layer.LayerRequestList -> App.ActionHandler Servant.NoContent
createNewLayer (Layer.LayerRequestList layerRequests) =
  newLayer (\lastModifiedTime ls -> mapM_ (\lr -> STMMap.insert (Layer.requestToLayer (Layer._newLayerRequestName lr) (Layer._newLayerRequestSettings lr) lastModifiedTime) (Layer._newLayerRequestName lr) ls) layerRequests)

--provisionLayer :: Text.Text -> Layer.LayerSettings -> App.ActionHandler Servant.NoContent
provisionLayer l settings =
  newLayer (\lastModifiedTime -> STMMap.insert (Layer.requestToLayer l settings lastModifiedTime) l)

newLayer :: (MonadIO.MonadIO m, ReaderClass.MonadReader App.ServerState m) => (UTCTime -> STMMap.Map Text.Text Layer.Layer -> STM a) -> m Servant.NoContent
newLayer b = do
  r <- ReaderClass.ask
  MonadLogger.logDebugNS "web" "hello"
  lastModifiedTime <- MonadIO.liftIO getCurrentTime
  let (ls, cfgFile, originalCfg) = (,,) <$> App._ssStateLayers <*> App._ssConfigFile <*> App._ssOriginalConfig $ r
  newLayers <- MonadIO.liftIO . atomically $ do
    _ <- b lastModifiedTime ls
    stmMapToList ls
  let newNewLayers = fmap (\(k, v) -> (k, Layer.layerToLayerDetails v)) newLayers
  MonadIO.liftIO $ ByteStringLazyChar8.writeFile cfgFile (AesonPretty.encodePretty (originalCfg {Config._configLayers = Map.fromList newNewLayers}))
  pure Servant.NoContent

serveLayer :: (MonadIO.MonadIO m) => Text.Text -> Natural -> Natural -> Text.Text -> Maybe Text.Text -> Maybe Text.Text -> App.ActionHandler m (Servant.Headers '[Servant.Header "Last-Modified" Text.Text] ByteString.ByteString)
serveLayer l z x stringY maybeToken maybeIfModified = do
  layer <- getLayerOrThrow l
  pool <- ReaderClass.asks App._ssPool
  cache <- ReaderClass.asks App._ssTokenAuthorisationCache
  layerAuthorisation <- MonadIO.liftIO $ LayerLib.checkLayerAuthorisation pool cache layer maybeToken
  case layerAuthorisation of
    LayerSecurity.Authorised ->
      getContent z x stringY maybeIfModified layer
    LayerSecurity.Unauthorised ->
      throwError layerNotFoundError

getContent :: (MonadIO.MonadIO m) => Natural -> Natural -> Text.Text -> Maybe Text.Text -> Layer.Layer -> App.ActionHandler m (Servant.Headers '[Servant.Header "Last-Modified"  Text.Text] ByteString.ByteString)
getContent z x stringY maybeIfModified layer =
  if Layer.isModified layer maybeIfModified
      then getContent' layer z x stringY
      else throwError Servant.err304

getContent' :: (MonadIO.MonadIO m) => Layer.Layer -> Natural -> Natural -> Text.Text -> App.ActionHandler m (Servant.Headers '[Servant.Header "Last-Modified" Text.Text] ByteString.ByteString)
getContent' l z x stringY
  | (".mvt" `Text.isSuffixOf` stringY) || (".pbf" `Text.isSuffixOf` stringY) || (".vector.pbf" `Text.isSuffixOf` stringY) = getAnything getTile l z x stringY
  | ".json" `Text.isSuffixOf` stringY = getAnything getJson l z x stringY
  | otherwise = throwError $ Servant.err400 { Servant.errBody = "Unknown request: " <> ByteStringLazyChar8.fromStrict (TE.encodeUtf8 stringY) }

getAnything :: (MonadIO.MonadIO m) => (t -> TypesGeography.ZoomLevel -> (TypesGeography.Pixels, TypesGeography.Pixels) -> App.ActionHandler m a) -> t -> TypesGeography.ZoomLevel -> TypesGeography.Pixels -> Text.Text -> App.ActionHandler m a
getAnything f layer z x stringY =
  case getY stringY of
    Left e       -> fail $ show e
    Right (y, _) -> f layer z (x, y)
  where
    getY s = DTR.decimal $ Text.takeWhile Char.isNumber s

getTile :: (MonadIO.MonadIO m) => Layer.Layer -> TypesGeography.ZoomLevel -> (TypesGeography.Pixels, TypesGeography.Pixels) -> App.ActionHandler m (Servant.Headers '[Servant.Header "Last-Modified" Text.Text] ByteString.ByteString)
getTile layer z xy = do
  buffer  <- ReaderClass.asks (^. App.ssBuffer)
  let simplificationAlgorithm = Layer.getAlgorithm z layer
      config = TypesConfig.mkConfig (Layer._layerName layer) z xy buffer Config.defaultTileSize (Layer.getLayerSetting layer Layer._layerQuantize) simplificationAlgorithm
      layerFormat = Layer.getLayerSetting layer Layer._layerFormat
  case layerFormat of
    LayerFormat.GeoJSON -> do
      geoFeature <- getGeoFeature layer z xy
      tile <- MonadIO.liftIO $ TileLib.mkTile (Layer._layerName layer) z xy buffer (Layer.getLayerSetting layer Layer._layerQuantize) simplificationAlgorithm geoFeature
      checkEmpty tile layer
    LayerFormat.WkbProperties -> do
      geoFeature <- getStreamingLayer config layer z xy
      checkEmpty (GeoJsonStreamingToMvt.vtToBytes config geoFeature) layer

checkEmpty :: (MonadIO.MonadIO m) => ByteString.ByteString -> Layer.Layer -> App.ActionHandler m (Servant.Headers '[Servant.Header "Last-Modified" Text.Text] ByteString.ByteString)
checkEmpty tile layer
  | ByteString.null tile = throwError $ App.err204 { Servant.errHeaders = [(hLastModified, TE.encodeUtf8 $ Layer.lastModified layer)] }
  | otherwise = pure $ Servant.addHeader (Layer.lastModified layer) tile

getJson :: (MonadIO.MonadIO m) => Layer.Layer -> TypesGeography.ZoomLevel -> (TypesGeography.Pixels, TypesGeography.Pixels) ->  App.ActionHandler m (Servant.Headers '[Servant.Header "Last-Modified" Text.Text] ByteString.ByteString)
getJson layer z xy = Servant.addHeader (Layer.lastModified layer) . ByteStringLazyChar8.toStrict . Aeson.encode <$> getGeoFeature layer z xy

getGeoFeature :: (MonadIO.MonadIO m) => Layer.Layer -> TypesGeography.ZoomLevel -> (TypesGeography.Pixels, TypesGeography.Pixels) -> App.ActionHandler m (Geospatial.GeoFeatureCollection Aeson.Value)
getGeoFeature layer z xy = do
  errorOrTfs <- DBLayer.findFeatures layer z xy
  case errorOrTfs of
    Left e    -> throwError $ Servant.err500 { Servant.errBody = ByteStringLazyChar8.pack $ show e }
    Right tfs -> pure $ Geospatial.GeoFeatureCollection Nothing tfs

getStreamingLayer :: (MonadIO.MonadIO m) => TypesConfig.Config -> Layer.Layer -> TypesGeography.ZoomLevel -> (TypesGeography.Pixels, TypesGeography.Pixels) -> App.ActionHandler m TypesMvtFeatures.StreamingLayer
getStreamingLayer config layer z xy = do
  errorOrTfs <- DBLayer.findFeaturesStreaming config layer z xy
  case errorOrTfs of
    Left e    -> throwError $ Servant.err500 { Servant.errBody = ByteStringLazyChar8.pack $ show e }
    Right tfs -> pure tfs

getLayerOrThrow :: (MonadIO.MonadIO m) => Text.Text -> App.ActionHandler m Layer.Layer
getLayerOrThrow l = do
  errorOrLayer <- getLayer l
  case errorOrLayer of
    Left Layer.LayerNotFound -> throwError layerNotFoundError
    Right layer              -> pure layer

getLayer :: (MonadIO.MonadIO m) => Text.Text -> App.ActionHandler m (Either Layer.LayerError Layer.Layer)
getLayer l = do
  ls <- ReaderClass.asks App._ssStateLayers
  result <- MonadIO.liftIO . atomically $ STMMap.lookup l ls
  pure $ case result of
    Nothing    -> Left Layer.LayerNotFound
    Just layer -> Right layer

layerNotFoundError :: Servant.ServantErr
layerNotFoundError =
  Servant.err404 { Servant.errBody = "Layer not found :-(" }
