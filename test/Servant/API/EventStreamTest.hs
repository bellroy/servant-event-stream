{-# LANGUAGE TypeApplications #-}

module Servant.API.EventStreamTest where

import Data.Proxy (Proxy (Proxy))
import Hedgehog (Property, forAll, property, (===))
import Servant.API (MimeUnrender (mimeUnrender), mimeRender)
import Servant.API.EventStream (EventStream, genServerEvent)
import Test.Tasty.Hedgehog

hprop_serverEventRoundTrip :: Property
hprop_serverEventRoundTrip = property $ do
  event <- forAll genServerEvent

  mimeUnrender (Proxy @EventStream) (mimeRender (Proxy @EventStream) event) === Right event
