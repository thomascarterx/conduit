{-# LANGUAGE OverloadedStrings, NoMonomorphismRestriction #-}
import Network.Wai.Application.Static

import Test.Hspec.Monadic
import Test.Hspec.QuickCheck
import Test.Hspec.HUnit ()
import Test.HUnit ((@?=), assert)
import Distribution.Simple.Utils (isInfixOf)
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.PosixCompat.Files (getFileStatus, modificationTime)
import System.IO (stderr, hPutStrLn)


import Network.Wai
import Network.Wai.Test

import Network.Socket.Internal as Sock
import qualified Network.HTTP.Types as H
import Control.Monad.IO.Class (liftIO)

defRequest :: Request
defRequest = Request {
  rawQueryString = ""
, queryString = []
, requestMethod = "GET"
, rawPathInfo = ""
, pathInfo = []
, requestHeaders = []
, serverName = "wai-test"
, httpVersion = H.http11
, serverPort = 80
, isSecure = False
, remoteHost = Sock.SockAddrUnix "/dev/null"
}

setRawPathInfo :: Request -> S8.ByteString -> Request
setRawPathInfo r rawPinfo = 
  let pInfo = T.split (== '/') $ TE.decodeUtf8 rawPinfo
  in  r { rawPathInfo = rawPinfo, pathInfo = pInfo }


-- debug :: String -> m0 ()
debug = liftIO . hPutStrLn stderr

main :: IO a
main = hspecX $ do
  let must = liftIO . assert

  let webApp = flip runSession $ staticApp defaultWebAppSettings  {ssFolder = fileSystemLookup "tests"}
  let fileServerApp = flip runSession $ staticApp defaultFileServerSettings  {ssFolder = fileSystemLookup "tests"}

  let etag = "1B2M2Y8AsgTpgAmY7PhCfg=="
  let file = "a/b"
  let statFile = setRawPathInfo defRequest file


  describe "Pieces: pathFromPieces" $ do
    it "converts to a file path" $
      (pathFromPieces "prefix" [Piece "a" "a", Piece "bc" "bc"]) @?= "prefix/a/bc"

    prop "each piece is in file path" $ \piecesS ->
      let pieces = map (\p -> Piece p "") piecesS
      in  all (\p -> ("/" ++ p) `isInfixOf` (pathFromPieces "root" $ pieces)) piecesS

  describe "webApp" $ do
    it "403 for unsafe paths" $ webApp $
      flip mapM_ ["..", "."] $ \path ->
        assertStatus 403 =<<
          request (setRawPathInfo defRequest path)

    it "200 for hidden paths" $ webApp $
      flip mapM_ [".hidden/folder.png", ".hidden/haskell.png"] $ \path ->
        assertStatus 200 =<<
          request (setRawPathInfo defRequest path)

    it "404 for non-existant files" $ webApp $
      assertStatus 404 =<<
        request (setRawPathInfo defRequest "doesNotExist")

    it "301 redirect when multiple slashes" $ webApp $ do
      req <- request (setRawPathInfo defRequest "a//b/c")
      assertStatus 301 req
      assertHeader "Location" "../../a/b/c" req

    let absoluteApp = flip runSession $ staticApp $ defaultWebAppSettings {
          ssFolder = fileSystemLookup "tests", ssMkRedirect = \_ u -> S8.append "http://www.example.com" u
        }
    it "301 redirect when multiple slashes" $ absoluteApp $
      flip mapM_ ["/a//b/c", "a//b/c"] $ \path -> do
        req <- request (setRawPathInfo defRequest path)
        assertStatus 301 req
        assertHeader "Location" "http://www.example.com/a/b/c" req

  describe "webApp when requesting a static asset" $ do
    it "200 and etag when no etag query parameters" $ webApp $ do
      req <- request statFile
      assertStatus 200 req
      assertNoHeader "Cache-Control" req
      assertHeader "ETag" etag req

    it "200 when no cache headers and bad cache query string" $ webApp $ do
      flip mapM_ [Just "cached", Nothing] $ \badETag -> do
        req <- request statFile { queryString = [("etag", badETag)] }
        assertStatus 301 req
        assertHeader "Location" "../a/b?etag=1B2M2Y8AsgTpgAmY7PhCfg%3D%3D" req
        assertNoHeader "Cache-Control" req

    it "Cache-Control set when etag parameter is correct" $ webApp $ do
      req <- request statFile { queryString = [("etag", Just etag)] }
      assertStatus 200 req
      assertHeader "Cache-Control" "max-age=31536000" req

    it "200 when invalid in-none-match sent" $ webApp $
      flip mapM_ ["cached", ""] $ \badETag -> do
        req <- request statFile { requestHeaders  = [("If-None-Match", badETag)] }
        assertStatus 200 req
        assertHeader "ETag" etag req

    it "304 when valid if-none-match sent" $ webApp $ do
      req <- request statFile { requestHeaders  = [("If-None-Match", etag)] }
      assertStatus 304 req
      assertNoHeader "Etag" req

  describe "fileServerApp" $ do
    it "directory listing for index" $ fileServerApp $ do
      resp <- request (setRawPathInfo defRequest "a/")
      assertStatus 200 resp
      let body = simpleBody resp
      let contains a b = isInfixOf b (L8.unpack a)
      must $ body `contains` "<img src=\"../.hidden/haskell.png\" />"
      must $ body `contains` "<img src=\"../.hidden/folder.png\" alt=\"Folder\" />"
      must $ body `contains` "<a href=\"b\">b</a>"

    it "200 when invalid if-modified-since header" $ fileServerApp $ do
      flip mapM_ ["123", ""] $ \badDate -> do
        req <- request statFile {
          requestHeaders = [("If-Modified-Since", badDate)]
        }
        assertStatus 200 req
        assertNoHeader "Cache-Control" req

    it "304 when if-modified-since matches" $ fileServerApp $ do
      stat <- liftIO $ getFileStatus file
      req <- request statFile {
        -- TODO: need actual time String
        requestHeaders = [("If-Modified-Since", S8.pack $ show $ modificationTime stat)]
      }
      assertStatus 304 req
      assertNoHeader "Cache-Control" req

