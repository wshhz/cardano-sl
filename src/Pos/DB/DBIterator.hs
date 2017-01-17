{-# LANGUAGE AllowAmbiguousTypes  #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Encapsulation of RocksDB iterator
module Pos.DB.DBIterator
       ( MonadDBIterator (..)
       , DBIterator (..)
       , DBMapIterator (..)
       , IterType
       , DBKeyIterator
       , DBValueIterator
       , runIterator
       , mapIterator
       ) where

import           Control.Monad.Reader (ReaderT (..))
import           Control.Monad.Trans  (MonadTrans)
import qualified Database.RocksDB     as Rocks
import           Universum

import           Pos.Binary.Class     (Bi)
import           Pos.DB.Class         (MonadDB (..))
import           Pos.DB.Functions     (WithKeyPrefix (..), rocksDecodeMaybe,
                                       rocksDecodeMaybeWP)
import           Pos.DB.Types         (DB (..))
import           Pos.Util.Iterator    (MonadIterator (..))

newtype DBIterator i m a = DBIterator
    { getDBIterator :: ReaderT Rocks.Iterator m a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadTrans
               , MonadThrow, MonadCatch)

-- | RocksDB key value iteration errors.
data ParseResult a = FetchError  -- RocksDB internal error
                                 -- caused by invalid database of smth else (on RocksDB side)
                   | DecodeError -- Parsing error caused by invalid format of data
                                 -- or not expected (key, value) pair.
                                 -- (For example we iterate by utxo (key, value)
                                 -- but encounter balance (key, value))
                   | Success a   -- Element is fetched and decoded successfully.
    deriving Show

-- | Iterator by keys of type @k@ and values of type @v@.
instance ( Bi k, Bi v
         , MonadIO m, MonadThrow m
         , MonadDBIterator i, k ~ IterKey i, v ~ IterValue i
         , WithKeyPrefix k)
         => MonadIterator (DBIterator i m) (k, v) where
    nextItem = do
        it <- DBIterator ask
        cur <- curItem
        Rocks.iterNext it
        return cur
    -- curItem returns first successfully fetched and parsed elements.
    curItem = do
        it <- DBIterator ask
        resk <- parseKey it
        case resk of
            FetchError  -> pure Nothing
            DecodeError -> Rocks.iterNext it >> curItem
            Success k   -> do
                resv <- parseVal it
                case resv of
                    FetchError  -> pure Nothing
                    DecodeError -> Rocks.iterNext it >> curItem
                    Success v   -> pure $ Just (k, v)
      where
        parseKey it =
            maybe FetchError (maybe DecodeError Success . rocksDecodeMaybeWP)
            <$> Rocks.iterKey it
        parseVal it =
            maybe FetchError (maybe DecodeError Success . rocksDecodeMaybe)
            <$> Rocks.iterValue it

-- | Encapsulate `map f elements`, where @elements@ - collection elements of type @a@.
-- Holds `DBIterator m a` and apply f for every `nextItem` and `curItem` call.
-- If f :: a -> b then we iterate by collection elements of type b.
newtype DBMapIterator i v m a = DBMapIterator
    { getDBMapIterator :: ReaderT (IterType i -> v) (DBIterator i m) a
    } deriving (Functor, Applicative, Monad, MonadIO, MonadThrow, MonadCatch)

type DBKeyIterator   i = DBMapIterator i (IterKey i)
type DBValueIterator i = DBMapIterator i (IterValue i)

instance MonadTrans (DBMapIterator i v)  where
    lift x = DBMapIterator $ ReaderT $ const $ lift x

-- -- | Instance for DBMapIterator using DBIterator.
-- -- Fetch every element from DBIterator and apply `f` for it.
instance ( Monad m
         , MonadIterator (DBIterator i m) (IterKey i, IterValue i))
         => MonadIterator (DBMapIterator i v m) v where
    nextItem = DBMapIterator $ ReaderT $ \f -> fmap f <$> nextItem
    curItem = DBMapIterator $ ReaderT $ \f -> fmap f <$> curItem

deriving instance MonadMask m => MonadMask (DBIterator i m)
--deriving instance MonadMask m => MonadMask (DBMapIterator i v m)

deriving instance MonadDB ssc m => MonadDB ssc (DBIterator i m)
deriving instance MonadDB ssc m => MonadDB ssc (DBMapIterator i v m)

class MonadDBIterator i where
    type IterKey   i :: *
    type IterValue i :: *
    iterKeyPrefix :: Proxy i -> ByteString

type IterType i = (IterKey i, IterValue i)
-- | Run DBIterator by `DB ssc`.
runIterator :: forall i a m ssc . (MonadIO m, MonadMask m)
             => DBIterator i m a -> DB ssc -> m a
runIterator dbIter DB{..} =
    bracket (Rocks.createIter rocksDB rocksReadOpts) (Rocks.releaseIter)
            (\it -> Rocks.iterFirst it >> runReaderT (getDBIterator dbIter) it)

-- | Run DBMapIterator by `DB ssc`.
mapIterator :: forall i v m ssc a . (MonadIO m, MonadMask m)
            => DBMapIterator i v m a
            -> (IterType i -> v)
            -> DB ssc
            -> m a
mapIterator dbIter f = runIterator (runReaderT (getDBMapIterator dbIter) f)
