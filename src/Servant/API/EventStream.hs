{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Servant.API.EventStream
  ( ServerSentEvents,
    ServerEvent (..),
    ToServerEventData (..),
    FromServerEventData (..),
    EventStream,
    EventSource,
    EventSourceHdr,
    eventSource,
    jsForAPI,
    genServerEvent,
  )
where

import Control.Lens
#if !MIN_VERSION_base(4,11,0)
import           Data.Semigroup
#endif
import Control.Applicative (many)
import qualified Data.Attoparsec.ByteString as A
import Data.Bifunctor (first, second)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as Char8
import Data.Char (ord)
import Data.Functor (void)
import Data.Kind (Type)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Data.Word (Word8)
import GHC.Generics (Generic)
import GHC.TypeNats (KnownNat, Nat)
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Network.HTTP.Media
  ( (//),
    (/:),
  )
import Servant
import Servant.Auth.Server (SetCookie)
import Servant.Auth.Server.Internal.AddSetCookie (AddSetCookieApi)
import Servant.Client (HasClient (..))
import qualified Servant.Client.Core as Client
import Servant.Foreign
import Servant.Foreign.Internal (_FunctionName)
import Servant.JS.Internal
import Servant.Types.SourceT (transformWithAtto)
import qualified Text.Megaparsec as P
import qualified Text.Megaparsec.Byte as P

{-
TODOs
  - CRLF
  - read/write retry fields
  - read/write comment fields
-}

data ServerEvent a = ServerEvent
  { eventName :: Maybe LBS.ByteString,
    eventId :: Maybe LBS.ByteString,
    eventData :: a
  }
  deriving stock (Show, Eq, Generic, Functor)

class ToServerEventData a where
  toRawEventData :: a -> LBS.ByteString

class FromServerEventData a where
  parseRawEventData ::
    ServerEvent LBS.ByteString ->
    Either Text (ServerEvent a)

instance ToServerEventData LBS.ByteString where
  toRawEventData = id

instance FromServerEventData LBS.ByteString where
  parseRawEventData = Right

instance ToServerEventData ByteString where
  toRawEventData = LBS.fromStrict

instance FromServerEventData ByteString where
  parseRawEventData = Right . fmap LBS.toStrict

encodeServerEvent :: ToServerEventData a => ServerEvent a -> LBS.ByteString
encodeServerEvent ServerEvent {..} = idBs <> nameBs <> mconcat dataBs <> "\n"
  where
    dataBs = fmap (\line -> "data:" <> line <> "\n") . Char8.lines $ toRawEventData eventData
    nameBs = encodeNoneDataField "event" eventName
    idBs = encodeNoneDataField "id" eventId
    encodeNoneDataField fieldName = maybe "" (\field -> fieldName <> ":" <> LBS.filter (/= newlineW8) field <> "\n")

serverEventParser :: FromServerEventData a => P.Parsec Void LBS.ByteString (ServerEvent a)
serverEventParser = do
  void $ many (P.try commentParser) -- skip leading comments
  fields <- Map.fromListWith (<>) . fmap (second (: [])) <$> many (P.try fieldParser)
  let eventField = Map.lookup "event" fields >>= safeHead
      idField = Map.lookup "id" fields >>= safeHead
      dataField :: LBS.ByteString = LBS.intercalate "\n" $ fromMaybe [] (Map.lookup "data" fields)
  case parseRawEventData ServerEvent {eventName = eventField, eventId = idField, eventData = dataField} of
    Left errMsg -> fail $ "failed to decode event data: " <> T.unpack errMsg
    Right event -> event <$ P.newline

fieldParser :: P.Parsec Void LBS.ByteString (LBS.ByteString, LBS.ByteString)
fieldParser = do
  label <- P.takeWhile1P Nothing (/= charToWord8 ':')
  void $ P.char (charToWord8 ':')
  value <- P.takeWhileP Nothing (/= newlineW8)
  void P.newline
  void $ many (P.try commentParser) -- skip trailing comments
  pure (label, value)

commentParser :: P.Parsec Void LBS.ByteString ()
commentParser =
  void $
    P.char (charToWord8 ':') *> P.takeWhileP Nothing (/= newlineW8)

newlineW8 :: Word8
newlineW8 = charToWord8 '\n'

charToWord8 :: Char -> Word8
charToWord8 = fromIntegral . ord

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

data ServerSentEvents method (status :: Nat) (a :: Type)
  deriving (Generic)

data ServerEventFraming

instance FramingRender ServerEventFraming where
  framingRender _ = fmap

instance FramingUnrender ServerEventFraming where
  framingUnrender _ f = transformWithAtto $ do
    bytes <- A.manyTill A.anyWord8 (A.string "\n\n")
    either fail pure . f $ LBS.pack bytes <> Char8.pack ("\n\n" :: String)

type ServerSideImpl method status a = Stream method status ServerEventFraming EventStream (EventSourceHdr a)

instance (ReflectMethod method, KnownNat status, ToServerEventData a) => HasServer (ServerSentEvents method status a) context where
  type ServerT (ServerSentEvents method status a) m = ServerT (ServerSideImpl method status a) m
  route Proxy =
    route
      (Proxy :: Proxy (ServerSideImpl method status a))
  hoistServerWithContext Proxy =
    hoistServerWithContext
      (Proxy :: Proxy (ServerSideImpl method status a))

-- | a helper instance for <https://hackage.haskell.org/package/servant-foreign-0.15.3/docs/Servant-Foreign.html servant-foreign>
instance
  (HasForeignType lang ftype (EventSourceHdr a), ReflectMethod method) =>
  HasForeign lang ftype (ServerSentEvents method status a)
  where
  type Foreign ftype (ServerSentEvents method status a) = Req ftype

  foreignFor lang Proxy Proxy req =
    req
      & reqFuncName . _FunctionName %~ ("stream" :)
      & reqMethod .~ method
      & reqReturnType ?~ retType
    where
      retType = typeFor lang (Proxy :: Proxy ftype) (Proxy :: Proxy (EventSourceHdr a))
      method = reflectMethod (Proxy :: Proxy method)

-- | A type representation of an event stream. It's responsible for setting proper content-type
--   and buffering headers, as well as for providing parser implementations for the streams.
--   Read more on <https://docs.servant.dev/en/stable/tutorial/Server.html#streaming-endpoints Servant Streaming Docs>
data EventStream

instance Accept EventStream where
  contentType _ = "text" // "event-stream" /: ("charset", "utf-8")

type EventSource a = SourceIO (ServerEvent a)

-- | This is mostly to guide reverse-proxies like
--   <https://www.nginx.com/resources/wiki/start/topics/examples/x-accel/#x-accel-buffering nginx>
type EventSourceHdr a = Headers '[Header "Set-Cookie" SetCookie, Header "X-Accel-Buffering" Text, Header "Cache-Control" Text] (EventSource a)

-- | See details at
--   https://hackage.haskell.org/package/wai-extra-3.1.6/docs/Network-Wai-EventSource-EventStream.html#v:eventToBuilder
instance ToServerEventData a => MimeRender EventStream (ServerEvent a) where
  mimeRender _ = encodeServerEvent

eventSource :: EventSource a -> EventSourceHdr a
eventSource = noHeader . addHeader @"X-Accel-Buffering" "no" . addHeader @"Cache-Control" "no-cache"

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

type ClientSideImpl method status a = Stream method status ServerEventFraming EventStream (EventSource a)

instance
  ( Client.RunClient m,
    Client.RunStreamingClient m,
    FromServerEventData a,
    ReflectMethod method
  ) =>
  HasClient m (ServerSentEvents method status a)
  where
  -- we don't need to parse the cache control related header on client side
  type Client m (ServerSentEvents method status a) = Client m (ClientSideImpl method status a)
  clientWithRoute ::
    Proxy m ->
    Proxy (ServerSentEvents method status a) ->
    Client.Request ->
    Client m (ServerSentEvents method status a)
  clientWithRoute p _ = clientWithRoute p (Proxy @(ClientSideImpl method status a))
  hoistClientMonad ::
    Proxy m ->
    Proxy (ServerSentEvents method status a) ->
    (forall x. m1 x -> m2 x) ->
    Client m1 (ServerSentEvents method status a) ->
    Client m2 (ServerSentEvents method status a)
  hoistClientMonad _ _ f = f

instance FromServerEventData a => MimeUnrender EventStream (ServerEvent a) where
  mimeUnrender :: Proxy EventStream -> LBS.ByteString -> Either String (ServerEvent a)
  mimeUnrender _ = first P.errorBundlePretty . P.runParser serverEventParser ""

genServerEvent :: Gen (ServerEvent LBS.ByteString)
genServerEvent =
  ServerEvent
    <$> Gen.maybe genFieldValue
    <*> Gen.maybe genFieldValue
    <*> genFieldValue

genFieldValue :: Gen LBS.ByteString
genFieldValue =
  LBS.fromStrict
    <$> Gen.utf8
      (Range.linear 0 100)
      (Gen.filter (/= '\n') Gen.unicode)

type instance AddSetCookieApi (ServerSentEvents method status a) = ServerSentEvents method status a
