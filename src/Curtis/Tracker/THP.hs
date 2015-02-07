module Curtis.Tracker.THP
    ( TRequest(..)
    , TStatus(..)
    , TEvent(..)
    , TResponse(..)
    , getTResp
    -- , getTRespTEST
    ) where

import           Curtis.Bencode
import           Curtis.Common
import           Control.Monad
import           Data.Bits
import           Data.Char
import           Data.Word
import           Data.Digest.SHA1
import           Data.List
import           Data.List.Split
import           Data.Maybe
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as C
import           Data.Attoparsec.ByteString
import           Network.Wreq
import           Control.Lens

getTResp = fmap ( ( marse parseBen
                  . L.toStrict
                  . (^. responseBody)
                  ) >=> parseTResp
                )
         . get
         . mkURL

-- prints info for diagnostics
-- getTRespTEST :: TRequest -> IO (Maybe (Either String TResponse))
-- getTRespTEST req = do
--     print $ mkURL req
--     resp <- get $ mkURL req
--     print resp
--     let ben = L.toStrict (resp ^. responseBody)
--     print "\n\n"
--     print $ marse parseBen ben
--     print "\n\n"
--     return ((( marse parseBen
--                   . L.toStrict
--                   . (^. responseBody)
--            ) >=> parseTResp) resp)

data TRequest = TRequest { tracker    :: String
                         , info_hash  :: B.ByteString
                         , peer_id    :: B.ByteString
                         , pport      :: Word
                         , status     :: TStatus
                         , compact    :: Bool
                         , no_peer_id :: Bool
                         , event      :: Maybe TEvent
                         , ip         :: Maybe String
                         , numwant    :: Maybe Word
                         , key        :: Maybe B.ByteString
                         , trackerid  :: Maybe String
                         }
  deriving Show

data TStatus = TStatus { uploaded   :: Integer
                       , downloaded :: Integer
                       , left       :: Integer
                       }
  deriving Show

data TEvent = Started | Stopped | Completed
  deriving Show

mkURL :: TRequest -> String
mkURL TRequest { tracker    = tracker'
               , info_hash  = info_hash'
               , peer_id    = peer_id'
               , pport      = pport'
               , status     = TStatus { uploaded   = uploaded'
                                      , downloaded = downloaded'
                                      , left       = left'
                                      }
               , compact    = compact'
               , no_peer_id = no_peer_id'
               , event      = event'
               , ip         = ip'
               , numwant    = numwant'
               , key        = key'
               , trackerid  = trackerid'
               }
  = tracker' ++ "?" ++ intercalate "&"
        ( [ "info_hash="  ++ urifyBS info_hash'
          , "peer_id="    ++ urifyBS peer_id'
          , "port="       ++ show pport'
          , "uploaded="   ++ show uploaded'
          , "downloaded=" ++ show downloaded'
          , "left="       ++ show left'
          ]
       ++ if compact'    then ["compact=1"] else []
       ++ if no_peer_id' then ["no_peer_id=1"] else []
       ++ catMaybes [ fmap (("event=" ++ ) . encodeEvent) event'
                    , fmap ("ip="        ++) ip'
                    , fmap (("numwant="   ++) . show) numwant'
                    , fmap (("key="       ++) . urifyBS) key'
                    , fmap ("trackerid=" ++) trackerid'
                    ]
        )
        
encodeEvent :: TEvent -> String
encodeEvent Started   = "started"
encodeEvent Stopped   = "stopped"
encodeEvent Completed = "completed"

data TResponse = TResponse { warning_response :: Maybe String
                           , interval         :: Integer
                           , min_interval     :: Maybe Integer
                           , tracker_id       :: Maybe String
                           , complete         :: Integer
                           , incomplete       :: Integer
                           -- left = non-compact (peerid, ip, port)
                           -- right = compact (no peerid)
                           , peers            :: Either [(B.ByteString, String, Integer)]
                                                        [(              String, Integer)]
                           }
                 deriving Show


parseTResp :: BValue -> Maybe (Either String TResponse)
parseTResp ben = do
    dict <- getDict ben
    case bookup "failure reason" dict of
         Just (BString reason) -> Just (Left $ C.unpack reason)
         Nothing     -> do
            interval'   <- bookup "interval"   dict >>= getInt
            complete'   <- bookup "complete"   dict >>= getInt
            incomplete' <- bookup "incomplete" dict >>= getInt
            peerStuff   <- bookup "peers"      dict
            peers'      <- parseUncompressedPeers peerStuff `mplus` parseCompressedPeers peerStuff
            return $ Right TResponse
                { warning_response = fmap C.unpack (bookup "warning_response" dict >>= getString)
                , interval = interval'
                , min_interval = bookup "min_interval" dict >>= getInt
                , tracker_id = fmap C.unpack (bookup "min_interval" dict >>= getString)
                , complete = complete'
                , incomplete = incomplete'
                , peers = peers'
                }

parseUncompressedPeers :: BValue -> Maybe (Either [(B.ByteString, String, Integer)] [(String, Integer)])
parseUncompressedPeers = fmap Left . (getList >=> mapM (getDict >=> \d ->
    do peer_id' <- bookup "peer id" d >>= getString
       ip'      <- bookup "ip"      d >>= getString
       port'    <- bookup "port"    d >>= getInt
       return (peer_id', C.unpack ip', port')))

parseCompressedPeers :: BValue -> Maybe (Either [(B.ByteString, String, Integer)] [(String, Integer)])
parseCompressedPeers = fmap (Right . map aux . chunksOf 6 . B.unpack) . getString
  where aux [a, b, c, d, e, f] = ( intercalate "." $ map show [a, b, c, d]
                                 , fromIntegral e * 256 + fromIntegral f
                                 )

urifyBS :: B.ByteString -> String
urifyBS = concatMap urify8 . B.unpack

urify8 :: Word8 -> String
urify8 byte = ['%', toHexHalf $ shiftR byte 4, toHexHalf $ byte .&. 15]

toHexHalf :: Word8 -> Char
toHexHalf = genericIndex "0123456789ABCDEF"
