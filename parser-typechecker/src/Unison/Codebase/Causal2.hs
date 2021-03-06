{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternSynonyms, ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module Unison.Codebase.Causal2 where

import           Prelude                 hiding ( head
                                                , read
                                                , sequence
                                                )
import           Control.Applicative            ( liftA2 )
import           Control.Lens                   ( (<&>) )
import           Control.Monad                  ( when )
import           Control.Monad.Extra            ( ifM )
import           Control.Monad.Loops            ( anyM )
import           Data.List                      ( foldl1' )
import           Unison.Hash                    ( Hash )
-- import qualified Unison.Hash                   as H
import qualified Unison.Hashable               as Hashable
import           Unison.Hashable                ( Hashable )
import           Data.Map                       ( Map )
import qualified Data.Map                      as Map
import           Data.Set                       ( Set )
import           Data.Foldable                  ( for_, toList )

{-
`Causal a` has 5 operations, specified algebraically here:

* `before : Causal m a -> Causal m a -> m Bool` defines a partial order on
            `Causal`.
* `head : Causal m a -> a`, which represents the "latest" `a` value in a causal
          chain.
* `one : a -> Causal m a`, satisfying `head (one hd) == hd`
* `cons : a -> Causal a -> Causal a`, satisfying `head (cons hd tl) == hd` and
          also `before tl (cons hd tl)`.
* `merge : CommutativeSemigroup a => Causal a -> Causal a -> Causal a`, which is
           associative and commutative and satisfies:
  * `before c1 (merge c1 c2)`
  * `before c2 (merge c1 c2)`
* `sequence : Causal a -> Causal a -> Causal a`, which is defined as
              `sequence c1 c2 = cons (head c2) (merge c1 c2)`.
  * `before c1 (sequence c1 c2)`
  * `head (sequence c1 c2) == head c2`
-}

newtype C0Hash a = C0Hash { unc0hash :: Hash }
  deriving (Eq, Ord, Show)

-- h is the type of the pure data structure that will be hashed and used as
-- an index; e.g. h = Branch00, e = Branch0 m
data Causal m h e
  = One { currentHash :: C0Hash h, head :: e }
  | Cons { currentHash :: C0Hash h, head :: e, tail :: (C0Hash h, m (Causal m h e)) }
  -- The merge operation `<>` flattens and normalizes for order
  | Merge { currentHash :: C0Hash h, head :: e, tails :: Map (C0Hash h) (m (Causal m h e)) }

-- A serializer `Causal m h e`. Nonrecursive -- only responsible for
-- writing a single node of the causal structure.
data Causal0 h e
  = One0 e
  | Cons0 e (C0Hash h)
  | Merge0 e (Set (C0Hash h))

-- Don't need to deserialize the `e` to calculate `before`.
data Raw h
  = OneRaw
  | ConsRaw (C0Hash h)
  | MergeRaw (Set (C0Hash h))

type Deserialize m h e = C0Hash h -> m (Causal0 h e)

read :: Functor m => Deserialize m h e -> C0Hash h -> m (Causal m h e)
read d h = go <$> d h where
  go = \case
    One0 e -> One h e
    Cons0 e tailHash -> Cons h e (tailHash, read d tailHash)
    Merge0 e tailHashes ->
      Merge h e (Map.fromList [(h, read d h) | h <- toList tailHashes ])

type Serialize m h e = C0Hash h -> Causal0 h e -> m ()

-- Sync a causal to some persistent store, stopping when hitting a Hash which
-- has already been written, according to the `exists` function provided.
sync :: Monad m => (C0Hash h -> m Bool) -> Serialize m h e -> Causal m h e -> m ()
sync exists serialize c = do
  b <- exists (currentHash c)
  when (not b) $ go c
  where
    go c = case c of
      One currentHash head -> serialize currentHash $ One0 head
      Cons currentHash head (tailHash, tailm) -> do
        -- write out the tail first, so what's on disk is always valid
        b <- exists tailHash
        when (not b) $ go =<< tailm
        serialize currentHash (Cons0 head tailHash)
      Merge currentHash head tails -> do
        for_ (Map.toList tails) $ \(hash, cm) -> do
          b <- exists hash
          when (not b) $ go =<< cm
        serialize currentHash (Merge0 head (Map.keysSet tails))

instance Eq (Causal m h a) where
  a == b = currentHash a == currentHash b

instance Ord (Causal m h a) where
  a <= b = currentHash a <= currentHash b

instance Hashable (C0Hash h) where
  tokens (C0Hash h) = Hashable.tokens h

merge :: (Monad m, Semigroup e) => Causal m h e -> Causal m h e -> m (Causal m h e)
a `merge` b =
  ifM (before a b) (pure b) . ifM (before b a) (pure a) $ case (a, b) of
    (Merge _ _ tls, Merge _ _ tls2) -> merge0 $ Map.union tls tls2
    (Merge _ _ tls, b) -> merge0 $ Map.insert (currentHash b) (pure b) tls
    (b, Merge _ _ tls) -> merge0 $ Map.insert (currentHash b) (pure b) tls
    (a, b) ->
      merge0 $ Map.fromList [(currentHash a, pure a), (currentHash b, pure b)]

-- Does `h2` incorporate all of `h1`?
before :: Monad m => Causal m h e -> Causal m h e -> m Bool
before h1 h2 = go h1 h2
 where
  -- stopping condition if both are equal
  go h1 h2 | h1 == h2 = pure True
  -- otherwise look through tails if they exist
  go _  (One _ _    ) = pure False
  go h1 (Cons _ _ tl) = snd tl >>= go h1
  -- `m1` is a submap of `m2`
  go (Merge _ _ m1) (Merge _ _ m2) | all (`Map.member` m2) (Map.keys m1) =
    pure True
  -- if not, see if `h1` is a subgraph of one of the tails
  go h1 (Merge _ _ tls) =
    (||) <$> pure (Map.member (currentHash h1) tls) <*> anyM (>>= go h1)
                                                             (Map.elems tls)
  -- Exponential algorithm of checking that all paths are present
  -- in `h2` isn't necessary because of how merges are flattened
  --go (Merge _ _ m1) h2@(Merge _ _ _)
  --  all (\h1 -> go h1 h2) (Map.elems m1)

instance (Monad m, Semigroup e) => Semigroup (m (Causal m h e)) where
  a <> b = do
    x <- a
    y <- b
    merge x y

-- implementation detail, form a `Merge`
merge0
  :: (Applicative m, Semigroup e) => Map (C0Hash h) (m (Causal m h e)) -> m (Causal m h e)
merge0 m =
  let e = if Map.null m
        then error "Causal.merge0 empty map"
        else foldl1' (liftA2 (<>)) (fmap head <$> Map.elems m)
      h = hash (Map.keys m) -- sorted order
  in  e <&> \e -> Merge (C0Hash h) e m

hash :: Hashable e => e -> Hash
hash = Hashable.accumulate'

step :: (Applicative m, Hashable e) => (e -> e) -> Causal m h e -> Causal m h e
step f c = f (head c) `cons` c

stepIf
  :: (Applicative m, Hashable e)
  => (e -> Bool)
  -> (e -> e)
  -> Causal m h e
  -> Causal m h e
stepIf cond f c = if (cond $ head c) then step f c else c

stepM
  :: (Applicative m, Hashable e) => (e -> m e) -> Causal m h e -> m (Causal m h e)
stepM f c = (`cons` c) <$> f (head c)

one :: Hashable e => e -> Causal m h e
one e = One (C0Hash $ hash e) e

cons :: (Applicative m, Hashable e) => e -> Causal m h e -> Causal m h e
cons e tl = Cons (C0Hash $ hash [hash e, unc0hash . currentHash $ tl]) e (currentHash tl, pure tl)
