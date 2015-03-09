{-# LANGUAGE Trustworthy          #-}
------------------------------------------------------------------------
-- |
-- Module      : AI.Rete.Net
-- Copyright   : (c) 2015 Konrad Grzanek
-- License     : BSD-style (see the file LICENSE)
-- Created     : 2015-03-05
-- Maintainer  : kongra@gmail.com
-- Stability   : experimental
------------------------------------------------------------------------
module AI.Rete.Net where

import           AI.Rete.Data
import           AI.Rete.Flow
import           Control.Monad (liftM, forM_)
import           Control.Monad.Trans.State.Strict (get, put)
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as Set

-- CREATING ALPHA MEMORY AND FEEDING IN INITIAL Wmes.

-- | Searches for an existing alpha memory for the given symbols or
-- creates a new one.
buildOrShareAmem :: Obj   ConstantOrVariable
                 -> Attr  ConstantOrVariable
                 -> Val   ConstantOrVariable
                 -> ReteM Amem
buildOrShareAmem (Obj o) (Attr a) (Val v) = do
  let f s = case s of { JustConstant c' -> c'; _ -> wildcardConstant }
      o'  = Obj  (f o)
      a'  = Attr (f a)
      v'  = Val  (f v)

  amems <- liftM reteAmems get
  let k = Wme o' a' v'

  case Map.lookup k amems of
    Just amem -> return amem -- Happily found.
    Nothing   -> do
      -- Let's create new Amem.
      amem <- liftM Amem genid
      rete <- get
      let amemState = createAmemState rete o' a' v'
      put
        rete { reteAmems      = Map.insert k    amem      (reteAmems      rete )
             , reteAmemStates = Map.insert amem amemState (reteAmemStates rete )}
      return amem
{-# INLINE buildOrShareAmem #-}

createAmemState :: Rete
                -> Obj Constant -> Attr Constant -> Val Constant
                -> AmemState
createAmemState rete o a v = loop wmes Map.empty Map.empty Map.empty
  where
    (Obj  o') = o
    (Attr a') = a
    (Val  v') = v
    isWild  s = s == wildcardConstant
    wmes      = Set.toList (wmesForAmemFeed (isWild o') (isWild a') (isWild v')
                                            (reteWorkingMemory rete) o a v)

    loop []        i1 i2 i3 = AmemState wmes i1 i2 i3 []
    loop (w:wmes') i1 i2 i3 = let (Wme wo wa wv) = w in
      loop wmes' (wmesIndexInsert wo w i1)
                 (wmesIndexInsert wa w i2)
                 (wmesIndexInsert wv w i3)
{-# INLINE createAmemState #-}

wmesForAmemFeed :: Bool -> Bool -> Bool
                -> WorkingMemory
                -> Obj Constant -> Attr Constant -> Val Constant
                -> Set.HashSet Wme
wmesForAmemFeed False False False workingMemory o a v =
  -- o a v
  s1 `Set.intersection` s2 `Set.intersection` s3
  where
    s1 = Map.lookupDefault Set.empty o (reteWmesByObj  workingMemory)
    s2 = Map.lookupDefault Set.empty a (reteWmesByAttr workingMemory)
    s3 = Map.lookupDefault Set.empty v (reteWmesByVal  workingMemory)

wmesForAmemFeed False False True workingMemory o a _ =
  -- o a *
  s1 `Set.intersection` s2
  where
    s1 = Map.lookupDefault Set.empty o (reteWmesByObj  workingMemory)
    s2 = Map.lookupDefault Set.empty a (reteWmesByAttr workingMemory)

wmesForAmemFeed False True False workingMemory o _ v =
  -- o * v
  s1 `Set.intersection` s2
  where
    s1 = Map.lookupDefault Set.empty o (reteWmesByObj workingMemory)
    s2 = Map.lookupDefault Set.empty v (reteWmesByVal workingMemory)

wmesForAmemFeed False True True workingMemory o _ _ =
  -- o * *
  Map.lookupDefault Set.empty o (reteWmesByObj workingMemory)

wmesForAmemFeed True False False workingMemory _ a v =
  -- * a v
  s1 `Set.intersection` s2
  where
    s1 = Map.lookupDefault Set.empty a (reteWmesByAttr workingMemory)
    s2 = Map.lookupDefault Set.empty v (reteWmesByVal  workingMemory)

wmesForAmemFeed True False True workingMemory _ a _ =
  -- * a *
  Map.lookupDefault Set.empty a (reteWmesByAttr workingMemory)

wmesForAmemFeed True True False workingMemory _ _ v =
  -- * * v
  Map.lookupDefault Set.empty v (reteWmesByVal workingMemory)

wmesForAmemFeed True True True workingMemory _ _ _ =
  -- * * *
  reteWmes workingMemory
{-# INLINE wmesForAmemFeed #-}

-- BETA MEMORY CREATION

buildOrShareBmem :: Join -> ReteM Bmem
buildOrShareBmem join = do
  joinStates <- liftM reteJoinStates get
  let joinState = Map.lookupDefault
                  (error ("PANIC (10): STATE NOT FOUND FOR " ++ show join))
                  join joinStates

  case joinChildBmem joinState of
    Just bmem -> return bmem  -- Happily found.
    Nothing   -> do
      -- Let's create new Bmem.
      bmem <- liftM Bmem genid
      let bmemState = BmemState [] []

      -- Update with matches from above:
      -- 0. Save join prods.
      let joinProds = joinChildProds joinState

      -- 1. Set bmem as singleton child of join.
      rete1 <- get
      let joinState1 = JoinState { joinChildBmem  = Just bmem
                                 , joinChildProds = [] }
      put rete1 { reteBmemStates = Map.insert bmem bmemState
                                   (reteBmemStates rete1)
                , reteJoinStates = Map.insert join joinState1 joinStates }

      -- 2. Right-activate-parent.
      let amem       = joinAmem join
          amemStates = reteAmemStates rete1
          amemState  = Map.lookupDefault
                       (error ("PANIC (11): STATE NOT FOUND FOR " ++ show amem))
                       amem amemStates
      forM_ (amemWmes amemState) $ \wme -> rightActivateJoin wme join

      -- 3. Restore new children and put all in place.
      rete2 <- get
      let joinState2  = joinState1 { joinChildProds = joinProds }
      put rete2 { reteJoinStates = Map.insert join joinState2
                                   (reteJoinStates rete2) }
      return bmem
{-# INLINE buildOrShareBmem #-}
