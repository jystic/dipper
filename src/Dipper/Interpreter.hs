{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

{-# OPTIONS_GHC -w #-}

module Dipper.Interpreter where

import           Data.Binary.Get
import           Data.Binary.Put
import qualified Data.ByteString as S
import           Data.ByteString.Builder
import qualified Data.ByteString.Lazy as L
import           Data.Dynamic
import           Data.Int (Int64)
import           Data.List (groupBy, foldl')
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe (maybeToList)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Typeable (Typeable)
import           Data.Word (Word8)

import           Dipper.AST
import           Dipper.Binary
import           Dipper.Types

------------------------------------------------------------------------

data File = File FilePath Tag RowFormat RowType
    deriving (Eq, Ord, Show)

data MSCR = MSCR {
    mscrInputs  :: [File]
  , mscrOutputs :: [File]
  , mscrMapper  :: [TaggedRow] -> [TaggedRow]
  , mscrReducer :: [TaggedRow] -> [TaggedRow]
  }

instance Show MSCR where
    showsPrec p MSCR{..} =
        showParen (p > 10) $ showString "MSCR "
                           . showsPrec 11 mscrInputs
                           . showString " "
                           . showsPrec 11 mscrOutputs

------------------------------------------------------------------------

test = decodeTagged schema (encodeTagged schema (take 10 xs))
  where
    xs = cycle [ 67 :*: "abcdefg" :*: S.empty
               , 67 :*: "123"     :*: S.empty
               , 22 :*: "1234"    :*: "Hello World!" ]

    schema = M.fromList [ (67, VarVInt :*: Fixed 0)
                        , (22, Fixed 4 :*: VarWord32be) ]

test1 = mscrMapper (interpret example1) xs
  where
    xs = [ 0 :*: "" :*: "00000000"
         , 0 :*: "" :*: "00000001"
         , 0 :*: "" :*: "00000002"
         , 0 :*: "" :*: "00000003"
         , 0 :*: "" :*: "00000004"
         , 0 :*: "" :*: "00000005"
         ]

test2 = mscrMapper (interpret example2) (take 10 xs)
  where
    xs = cycle [ 0 :*: "" :*: "00000000"
               , 1 :*: "" :*: "11111111"
               , 2 :*: "" :*: "22222222"
               , 3 :*: "" :*: "33333333"
               ]

------------------------------------------------------------------------

interpret :: Term String () -> MSCR
interpret term = MSCR{..}
  where
    mscrInputs      = readsOfTerm  0 term
    mscrOutputs     = writesOfTerm 0 term
    mscrMapper rows = evalTerm M.empty
                    . replaceWrites freshNames
                    $ replaceReads rows term

evalTerm :: (Ord n, Show n) => Map n Dynamic -> Term n TaggedRow -> [TaggedRow]
evalTerm env term = case term of
    Let (Name n) tl tm ->
      let
          env' = M.insert n (toDyn (evalTail env tl)) env
      in
          evalTerm env' tm

    Return tl -> evalTail env tl
    Run _  _  -> error ("evalTerm: cannot eval: " ++ show term)

evalTail :: forall n a. (Ord n, Show n) => Map n Dynamic -> Tail n a -> [a]
evalTail env tl = case tl of
    Concat        xss -> concatMap resolve xss
    ConcatMap   f  xs -> concatMap f (resolve xs)
    GroupByKey     xs -> group (resolve xs)
    FoldValues f x xs -> fold f x (resolve xs)
    ReadFile  _       -> error ("evalTail: cannot eval: " ++ show tl)
    WriteFile _ _     -> error ("evalTail: cannot eval: " ++ show tl)
  where
    resolve :: (Ord n, Show n) => Atom n b -> [b]
    resolve (Var (Name n)) = unsafeDynLookup "evalTail" n env
    resolve (Const xs)     = xs

    fold :: (v -> v -> v) -> v -> [k :*: [v]] -> [k :*: v]
    fold f x xs = map (\(k :*: vs) -> k :*: foldl' f x vs) xs

    group :: Eq k => [k :*: v] -> [k :*: [v]]
    group = map fixGroup . groupBy keyEq

    keyEq :: Eq k => k :*: v -> k :*: v -> Bool
    keyEq (x :*: _) (y :*: _) = x == y

    fixGroup :: [k :*: v] -> k :*: [v]
    fixGroup []                = error "evalTail: groupBy yielded empty list: impossible"
    fixGroup ((k :*: v) : kvs) = k :*: (v : map snd' kvs)

------------------------------------------------------------------------

replaceReads :: [TaggedRow] -> Term n a -> Term n a
replaceReads = replaceReadsOfTerm 0

replaceReadsOfTerm :: Tag -> [TaggedRow] -> Term n a -> Term n a
replaceReadsOfTerm tag rows term = case term of
    Let n (ReadFile path :: Tail n b) tm ->

      let
          xs :: [b]
          xs = map (decodeRow . snd')
                   (filter (hasTag tag) rows)

          tag' = nextTag "replaceReadsOfTerm" tag
      in
          Let n (Concat [Const xs]) (replaceReadsOfTerm tag' rows tm)

    Let n  tl tm -> Let n  tl (replaceReadsOfTerm tag rows tm)
    Run    tl tm -> Run    tl (replaceReadsOfTerm tag rows tm)
    Return tl    -> Return tl

------------------------------------------------------------------------

nextTag :: String -> Tag -> Tag
nextTag msg tag | tag /= maxBound = tag + 1
                | otherwise       = error msg'
  where
    msg' = msg ++ ": exceeded maximum number of tags <" ++ show tag ++ ">"

------------------------------------------------------------------------

replaceWrites :: [n] -> Term n () -> Term n TaggedRow
replaceWrites = replaceWritesOfTerm 0 []

replaceWritesOfTerm :: forall n. Tag -> [Name n TaggedRow] -> [n] -> Term n () -> Term n TaggedRow
replaceWritesOfTerm tag outs fresh term = case term of

    Run    tl tm -> case replaceWritesOfTail tag tl of
      Nothing  -> Run tl (replaceWritesOfTerm tag outs fresh tm)
      Just tl' -> replaceWithLet tl' tm

    Let n  tl tm -> case replaceWritesOfTail tag tl of
      Nothing  -> Let n tl (replaceWritesOfTerm tag outs fresh tm)
      Just tl' -> replaceWithLet tl' tm

    Return tl    -> case replaceWritesOfTail tag tl of
      Nothing  -> Return (Concat (map Var outs))
      Just tl' -> replaceWithLet tl' (Return (Concat []))

  where
    replaceWithLet :: Typeable n => Tail n TaggedRow -> Term n () -> Term n TaggedRow
    replaceWithLet tl' tm =
      let
          (n:fresh') = fresh
          name       = Name n

          tag'  = nextTag "replaceWritesOfterm" tag
          outs' = name : outs
      in
          Let name tl' (replaceWritesOfTerm tag' outs' fresh' tm)


replaceWritesOfTail :: Tag -> Tail n a -> Maybe (Tail n TaggedRow)
replaceWritesOfTail tag tl = case tl of
    WriteFile path (xs :: Atom n b) -> Just (ConcatMap go xs)
    _                               -> Nothing
  where
    go :: Row b => b -> [TaggedRow]
    go x = [tag :*: encodeRow x]

------------------------------------------------------------------------

readsOfTerm :: Tag -> Term n a -> [File]
readsOfTerm tag term = case term of
    Let (Name n) (ReadFile path :: Tail n b) tm ->

      let
          tag' = nextTag "readsOfTerm" tag
      in
          (File path tag (rowFormat (undefined :: b))
                         (rowType   (undefined :: b))) : readsOfTerm tag' tm

    Let _  _ tm -> readsOfTerm tag tm
    Run    _ tm -> readsOfTerm tag tm
    Return _    -> []

writesOfTerm :: Tag -> Term n a -> [File]
writesOfTerm tag term = case term of
    Run    tl tm -> go (writesOfTail tag tl) (\tg -> writesOfTerm tg tm)
    Let _  tl tm -> go (writesOfTail tag tl) (\tg -> writesOfTerm tg tm)
    Return tl    -> go (writesOfTail tag tl) (const [])
  where
    go (Just file) f = [file] ++ f tag'
    go Nothing     f = f tag

    tag' = nextTag "writesOfTerm" tag

writesOfTail :: Tag -> Tail n a -> Maybe File
writesOfTail tag tl = case tl of
    WriteFile path (xs :: Atom n b) -> Just (File path tag (rowFormat (undefined :: b))
                                                           (rowType   (undefined :: b)))
    _                               -> Nothing

------------------------------------------------------------------------

decodeTagged :: Map Tag RowFormat -> L.ByteString -> [TaggedRow]
decodeTagged schema bs =
    -- TODO this is unlikely to have good performance
    case runGetOrFail (getTagged schema) bs of
        Left  (_,   _, err)            -> error ("decodeTagged: " ++ err)
        Right (bs', o, x) | L.null bs' -> [x]
                          | otherwise  -> x : decodeTagged schema bs'

encodeTagged :: Map Tag RowFormat -> [TaggedRow] -> L.ByteString
encodeTagged schema = runPut . mapM_ (putTagged schema)

getTagged :: Map Tag RowFormat -> Get TaggedRow
getTagged schema = do
    tag <- getWord8
    case M.lookup tag schema of
      Nothing              -> fail ("getTagged: invalid tag <" ++ show tag ++ ">")
      Just (kFmt :*: vFmt) -> pure tag <&> getFormatted kFmt <&> getFormatted vFmt

putTagged :: Map Tag RowFormat -> TaggedRow -> Put
putTagged schema (tag :*: k :*: v) =
    case M.lookup tag schema of
      Nothing              -> fail ("putTagged: invalid tag <" ++ show tag ++ ">")
      Just (kFmt :*: vFmt) -> putWord8 tag >> putFormatted kFmt k >> putFormatted vFmt v

getFormatted :: ByteFormat -> Get S.ByteString
getFormatted VarVInt     = getByteString =<< getVInt
getFormatted VarWord32be = getByteString . fromIntegral =<< getWord32be
getFormatted (Fixed n)   = getByteString n

putFormatted :: ByteFormat -> S.ByteString -> Put
putFormatted fmt bs = case fmt of
    VarVInt                 -> putVInt     len  >> putByteString bs
    VarWord32be             -> putWord32be lenW >> putByteString bs
    (Fixed n)   | n == len  -> putByteString bs
                | otherwise -> fail ("putTagged: incorrect tag size: "
                                  ++ "expected <" ++ show n ++ " bytes> "
                                  ++ "but was <" ++ show len ++ " bytes>")
  where
    len  = S.length bs
    lenW = fromIntegral (S.length bs)