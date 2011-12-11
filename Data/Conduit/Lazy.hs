{-# LANGUAGE FlexibleContexts #-}
-- | Use lazy I/O. Warning: All normal warnings of lazy I/O apply. However, if
-- you consume the content within the ResourceT, you should be safe.
module Data.Conduit.Lazy
    ( lazyConsume
    ) where

import Data.Conduit
import System.IO.Unsafe (unsafeInterleaveIO)
import Control.Monad.Trans.Control
import Control.Monad.Trans.Resource

lazyConsume :: SourceM IO a -> ResourceT IO [a]
lazyConsume (SourceM msrc) = msrc >>= go

go :: Source IO a -> ResourceT IO [a]
go src =
    ResourceTT go'
  where
    go' r = unsafeInterleaveIO $ do
        let (ResourceTT msx) = sourcePull src
        sx <- msx r
        case sx of
            EOF -> return []
            Chunks x -> do
                y <- go' r
                return $ x ++ y