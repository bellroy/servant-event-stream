{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Servant.API.EventStream
  ( ServerSentEvents,
    EventStream,
    EventSource,
    EventSourceHdr,
    eventSource,
    jsForAPI,
    genServerEvent,
    ServerEventWrapper (..),
  )
where

import Control.Lens
import Data.Binary.Builder (Builder, toLazyByteString)
#if !MIN_VERSION_base(4,11,0)
import           Data.Semigroup
#endif
import Control.Applicative (Alternative ((<|>)), many)
import Data.Bifunctor (first, second)
import qualified Data.Binary.Builder as Builder
import qualified Data.ByteString.Lazy as LBS
import Data.Char (ord)
import Data.Functor (void)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Data.Word (Word8)
import Debug.Trace (traceShowId)
import GHC.Generics (Generic)
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Network.HTTP.Media
  ( (//),
    (/:),
  )
import Network.Wai.EventSource (ServerEvent (..))
import Network.Wai.EventSource.EventStream
  ( eventToBuilder,
  )
import Servant
import Servant.Client (HasClient (..))
import qualified Servant.Client.Core as Client
import Servant.Foreign
import Servant.Foreign.Internal (_FunctionName)
import Servant.JS.Internal
import qualified Text.Megaparsec as P
import qualified Text.Megaparsec.Byte as P
import qualified Text.Megaparsec.Byte.Lexer as P (decimal, signed)

data ServerSentEvents
  deriving (Generic)

type ServerSideVerb = StreamGet NoFraming EventStream EventSourceHdr

instance HasServer ServerSentEvents context where
  type ServerT ServerSentEvents m = ServerT ServerSideVerb m
  route Proxy =
    route
      (Proxy :: Proxy ServerSideVerb)
  hoistServerWithContext Proxy =
    hoistServerWithContext
      (Proxy :: Proxy ServerSideVerb)

-- | a helper instance for <https://hackage.haskell.org/package/servant-foreign-0.15.3/docs/Servant-Foreign.html servant-foreign>
instance
  (HasForeignType lang ftype EventSourceHdr) =>
  HasForeign lang ftype ServerSentEvents
  where
  type Foreign ftype ServerSentEvents = Req ftype

  foreignFor lang Proxy Proxy req =
    req
      & reqFuncName . _FunctionName %~ ("stream" :)
      & reqMethod .~ method
      & reqReturnType ?~ retType
    where
      retType = typeFor lang (Proxy :: Proxy ftype) (Proxy :: Proxy EventSourceHdr)
      method = reflectMethod (Proxy :: Proxy 'GET)

-- | A type representation of an event stream. It's responsible for setting proper content-type
--   and buffering headers, as well as for providing parser implementations for the streams.
--   Read more on <https://docs.servant.dev/en/stable/tutorial/Server.html#streaming-endpoints Servant Streaming Docs>
data EventStream

instance Accept EventStream where
  contentType _ = "text" // "event-stream" /: ("charset", "utf-8")

type EventSource = SourceIO ServerEvent

-- | This is mostly to guide reverse-proxies like
--   <https://www.nginx.com/resources/wiki/start/topics/examples/x-accel/#x-accel-buffering nginx>
type EventSourceHdr = Headers '[Header "X-Accel-Buffering" Text, Header "Cache-Control" Text] EventSource

-- | See details at
--   https://hackage.haskell.org/package/wai-extra-3.1.6/docs/Network-Wai-EventSource-EventStream.html#v:eventToBuilder
instance MimeRender EventStream ServerEvent where
  mimeRender _ = maybe "" toLazyByteString . eventToBuilder

eventSource :: EventSource -> EventSourceHdr
eventSource = addHeader @"X-Accel-Buffering" "no" . addHeader @"Cache-Control" "no-cache"

jsForAPI ::
  ( HasForeign NoTypes NoContent api,
    GenerateList NoContent (Foreign NoContent api)
  ) =>
  Proxy api ->
  Text
jsForAPI p =
  gen
    (listFromAPI (Proxy :: Proxy NoTypes) (Proxy :: Proxy NoContent) p)
  where
    gen :: [Req NoContent] -> Text
    gen = mconcat . map genEventSource

    genEventSource :: Req NoContent -> Text
    genEventSource req =
      T.unlines
        [ "",
          fname <> " = function(" <> argsStr <> ")",
          "{",
          "  s = new EventSource(" <> url <> ", conf);",
          "  Object.entries(eventListeners).forEach(([ev, cb]) => s.addEventListener(ev, cb));",
          "  return s;",
          "}"
        ]
      where
        argsStr = T.intercalate ", " args
        args =
          captures
            ++ map (view $ queryArgName . argPath) queryparams
            ++ ["eventListeners = {}", "conf"]

        captures =
          map (view argPath . captureArg)
            . filter isCapture
            $ req ^. reqUrl . path

        queryparams = req ^.. reqUrl . queryStr . traverse

        fname = "var " <> toValidFunctionName (camelCase $ req ^. reqFuncName)
        url = if url' == "'" then "'/'" else url'
        url' = "'" <> urlArgs
        urlArgs = jsSegments $ req ^.. reqUrl . path . traverse

type ClientSideVerb = StreamGet NoFraming EventStream EventSource

instance (Client.RunClient m, Client.RunStreamingClient m) => HasClient m ServerSentEvents where
  -- we don't need to parse the cache control related header on client side
  type Client m ServerSentEvents = Client m ClientSideVerb
  clientWithRoute ::
    Proxy m ->
    Proxy ServerSentEvents ->
    Client.Request ->
    Client m ServerSentEvents
  clientWithRoute p _ = clientWithRoute p (Proxy @ClientSideVerb)
  hoistClientMonad ::
    Proxy m ->
    Proxy ServerSentEvents ->
    (forall x. m1 x -> m2 x) ->
    Client m1 ServerSentEvents ->
    Client m2 ServerSentEvents
  hoistClientMonad _ _ f = f

instance MimeUnrender EventStream ServerEvent where
  mimeUnrender :: Proxy EventStream -> LBS.ByteString -> Either String ServerEvent
  mimeUnrender _ = first P.errorBundlePretty . P.runParser serverEventParser ""

serverEventParser :: P.Parsec Void LBS.ByteString ServerEvent
serverEventParser =
  (P.try commentParser <|> P.try retryParser <|> ordinaryServerEventParser) <* P.newline

-- for the constructor 'ServerEvent'
ordinaryServerEventParser :: P.Parsec Void LBS.ByteString ServerEvent
ordinaryServerEventParser = do
  fields <- Map.fromListWith (<>) . fmap (second (: [])) <$> many (P.try fieldParser)
  let eventField = fmap Builder.fromLazyByteString $ Map.lookup "event" fields >>= safeHead
      idField = fmap Builder.fromLazyByteString $ Map.lookup "id" (traceShowId fields) >>= safeHead
      dataFields = reverse $ Builder.fromLazyByteString <$> fromMaybe [] (Map.lookup "data" fields)
  pure ServerEvent {eventName = eventField, eventId = idField, eventData = dataFields}

fieldParser :: P.Parsec Void LBS.ByteString (LBS.ByteString, LBS.ByteString)
fieldParser = do
  label <- P.takeWhile1P Nothing (/= charToWord8 ':')
  void $ P.char (charToWord8 ':')
  value <- P.takeWhileP Nothing (/= charToWord8 '\n')
  void P.newline
  pure (label, value)

commentParser :: P.Parsec Void LBS.ByteString ServerEvent
commentParser =
  fmap (CommentEvent . Builder.fromLazyByteString) $
    P.char (charToWord8 ':') *> P.takeWhileP Nothing (/= charToWord8 '\n')

retryParser :: P.Parsec Void LBS.ByteString ServerEvent
retryParser = do
  void $ P.chunk "retry:"
  RetryEvent <$> P.signed (pure ()) P.decimal

charToWord8 :: Char -> Word8
charToWord8 = fromIntegral . ord

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

newtype ServerEventWrapper = ServerEventWrapper {unwrapServerEvent :: ServerEvent}

instance Show ServerEventWrapper where
  show (ServerEventWrapper event) = show $ eventToBuilder event

instance Eq ServerEventWrapper where
  ServerEventWrapper e1 == ServerEventWrapper e2 =
    fmap Builder.toLazyByteString (eventToBuilder e1)
      == fmap Builder.toLazyByteString (eventToBuilder e2)

genServerEvent :: Gen ServerEventWrapper
genServerEvent =
  ServerEventWrapper
    <$> Gen.choice
      [ ServerEvent <$> Gen.maybe genFieldValue <*> Gen.maybe genFieldValue <*> Gen.list (Range.linear 0 5) genFieldValue,
        CommentEvent <$> genFieldValue,
        RetryEvent <$> Gen.integral (Range.linear (-20) 20)
      ]

genFieldValue :: Gen Builder
genFieldValue =
  Builder.fromByteString
    <$> Gen.utf8
      (Range.linear 0 100)
      (Gen.filter (/= '\n') Gen.unicode)
