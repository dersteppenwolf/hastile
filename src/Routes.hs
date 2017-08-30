{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators         #-}

module Routes where

import           Data.ByteString as BS
import           Data.Proxy      as P
import           Data.Text       as T
import           Servant

import           Types

type LayerName = Capture "layer" Text
type Z = Capture "z" Integer
type X = Capture "x" Integer
type Y = Capture "y" Text
type YI = Capture "y" Integer

type HastileApi =
  Get '[JSON] InputConfig
    :<|> LayerName :> ReqBody '[JSON] LayerQuery :> Post '[JSON] NoContent
    :<|> LayerName :> Z :> X :> YI :> "query" :> Get '[PlainText] Text
    :<|> LayerName :> Z :> X :> Y :> Get '[MapboxVectorTile, AlreadyJSON] (Headers '[Header "Last-Modified" String] BS.ByteString)

hastileApi :: P.Proxy HastileApi
hastileApi = P.Proxy

