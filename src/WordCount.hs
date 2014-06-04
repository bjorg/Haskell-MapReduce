-- | Classic word count MapReduce algorithm written with the monad
--
--   Takes as argument:
--
--   * The name of file of word-based text
--
--   * (Optional) the number of mappers to use in the first stage
--     (defaults to 16)
module Main where

import Prelude hiding ((>>=))

import Parallel.MapReduce.Simple (distribute,lift,run,(>>=))
import System.IO (openFile, hGetContents, hPutStr, hClose, IOMode(..))
import System.Environment (getArgs)

showNice :: [(String,Int)] -> IO()
showNice [] = return ()
showNice (x:xs) = do
        putStrLn $ fst x ++ " occurs "++ show ( snd x) ++ " times"
        showNice xs

main::IO()
main = do
        args <- getArgs
        out <- case length args of
                0 -> error "Usage: wordcount [filename] ([num mappers])"
                _ -> do
                        let nMap = case length args of
                                1 -> 16
                                _ -> read $ args!!1
                        state <- getLines (head args)
                        let res = mapReduce nMap state
                        return res
        showNice out
    where
        mapReduce :: Int        -- ^ The number of mappers to use on the first stage
            -> [String]         -- ^ The list of words to count
            -> [(String,Int)]   -- ^ The list of word / count pairs
        mapReduce n = run (distribute n >>= lift mapper >>= lift reducer)

-- put data

putLines :: FilePath -> [String] -> IO ()
putLines file text = do
        h <- openFile file WriteMode
        hPutStr h $ unwords text
        hClose h
        return ()

-- get input

getLines :: FilePath -> IO [String]
getLines file = do
        h <- openFile file ReadMode
        text <- hGetContents h
        return $ words text

-- transformers
mapper :: [String] -> [(String,String)]
mapper [] = []
mapper (x:xs) = parse x ++ mapper xs
    where
        parse x' = map (\w -> (w,w)) $ words x'

reducer :: [String] -> [(String,Int)]
reducer [] = []
reducer xs = [(head xs,length xs)]
