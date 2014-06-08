{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

-- | Module that defines the 'MapReduce' monad and exports the necessary functions.
--
--   Mapper/reducers are generalised to functions of type
--   @a -> ([(s, a)] -> [(s', b)])@ which are combined using the monad's bind
--   operation.  The resulting monad is executed on initial data by invoking
--   'runMapReduce'.
--
--   For programmers only wishing to write conventional map/reduce algorithms,
--   which use functions of type @([s] -> [(s', b)])@ a wrapper function
--   'liftMR' is provided, which converts such a function into the
--   appropriate monadic function.
module Parallel.MapReduce (
-- * Types
        MapReduce,
-- * Functions
--
-- ** Monadic operations
        return, (>>=),
-- ** Helper functions
        run, distribute, lift
) where

import Prelude hiding (return,(>>=))

import Control.Applicative ((<$>))
import Control.DeepSeq (NFData)
import Control.Parallel.Strategies (parMap, rdeepseq)
import Data.List (nub)

-- | Generalised version of 'Monad' which depends on a pair of 'Tuple's, both
--   of which change when '>>=' is applied.
class MonadG m where
    return :: a                     -- ^ value.
        -> m s x s a            -- ^ transformation that inserts the value
                                --   by replacing all
                                --   the key values with the specified
                                --   value, leaving the data unchanged.


    (>>=)  :: (Eq b, NFData s'', NFData c) =>
        m s a s' b              -- ^ Initial processing chain
        -> ( b -> m s' b s'' c )-- ^ Transformation to append to it
        -> m s a s'' c          -- ^ Extended processing chain


-- | The basic type that provides the MapReduce monad (strictly a generalised monad).
-- In the definition
-- @(s, a)@ is the type of the entries in the list of input data and @(s', b)@
-- that of the entries in the list of output data, where @s@ and @s'@ are data
-- and @a@ and @b@ are keys.
--
-- 'MapReduce' represents the transformation applied to data by one or more
--  MapReduce staged.  Input data has type @[(s, a)]@ and output data has type
--  @[(s', b)]@ where @s@ and @s'@ are data types and @a@, @b@ are key types.
--
--  Its structure is intentionally opaque to application programmers.
newtype MapReduce s a s' b = MR { runMR :: [(s, a)] -> [(s', b)] }

-- | Make MapReduce into a 'MonadG' instance
instance MonadG MapReduce where
    return = returnMR
    (>>=)  = bindMR

-- | Insert a value into 'MapReduce' by replacing all the keys with the
--   specified key, leaving the values unchanged.
returnMR :: a                       -- ^ Key
    -> MapReduce s x s a            -- ^ Transformation that inserts the value
                                    --   into 'MapReduce' by replacing all
                                    --   the keys with the specified
                                    --   key, leaving the values unchanged.
returnMR key = MR (\pairs -> [(value, key) | value <- fst <$> pairs])

-- ^ Apply a generalised mapper/reducer to the end of a chain of processing
--   operations to extend the chain.
bindMR :: (Eq b, NFData s'', NFData c) =>
    MapReduce s a s' b              -- ^ Initial state of the monad
    -> (b -> MapReduce s' b s'' c)  -- ^ Transformation to append to it
    -> MapReduce s a s'' c          -- ^ Extended transformation chain
bindMR mr liftedMapperReducer = MR (\pairs ->
    let
        newPairs = runMR mr pairs
        newUniqueKeys = nub $ snd <$> newPairs
        partitionedMRs = map liftedMapperReducer newUniqueKeys
    in
        concat $ parallelMap (`runMR` newPairs) partitionedMRs)
    where
        -- | The parallel map function; it must be functionally identical to 'map',
        --   distributing the computation across all available nodes in some way.
        parallelMap :: (NFData b) => (a -> b) -> [a] -> [b]
        parallelMap = parMap rdeepseq

-- | Execute a MapReduce MonadG given specified initial data.  Therefore, given
--   a 'MapReduce' @mr@ and initial data @values@ we apply the processing represented
--   by @mr@ to @values@ by executing
--
--   @run mr values@
run :: MapReduce s () s' b  -- ^ 'MapReduce' representing the required processing
    -> [s]                  -- ^ Initial data
    -> [(s', b)]            -- ^ Result of applying the processing to the data
run mr values = runMR mr [(value, ()) | value <- values]

-- | Function used at the start of processing to determine how many threads of processing
--   to use.  Should be used as the starting point for building a 'MapReduce'.
--   Therefore a generic 'MapReduce' should look like
--
--   @'distribute' '>>=' f1 '>>=' . . . '>>=' fn@
distribute :: Int           -- ^ Number of threads across which to distribute initial data
    -> MapReduce s () s Int -- ^ The 'MapReduce' required to do this
distribute n = MR (\pairs -> zipWith (\value key -> (value, key `mod` n)) (fst <$> pairs) [0..])


-- | The wrapper function that lifts mappers/reducers into the 'MapReduce'
--   monad.  Application programmers can use this to apply MapReduce transparently
--   to their mappers/reducers without needing to know any details of the implementation
--   of MapReduce.
--
--   Therefore the generic 'MapReduce' using only traditional mappers and
--   reducers should look like
--
--   @'distribute' '>>=' 'lift' f1 '>>=' . . . '>>=' 'lift' fn@
lift :: (Eq a) => ([s] -> [(s', b)])    -- traditional mapper/reducer of signature
                                        --  @([s] -> [(s',b)]@
    -> a                                -- the input key
    -> MapReduce s a s' b               -- the mapper/reducer wrapped as an instance of 'MapReduce'
lift f key = MR (\pairs -> f $ fst <$> filter (\pair -> key == snd pair) pairs)
